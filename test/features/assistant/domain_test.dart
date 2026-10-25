import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:athlete_os/features/assistant/domain/briefing_builder.dart';
import 'package:athlete_os/features/assistant/domain/hashing.dart';
import 'package:athlete_os/features/assistant/domain/reply_policy_engine.dart';
import 'package:athlete_os/features/assistant/domain/sensitivity_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

const _sms = 'com.google.android.apps.messaging';

void main() {
  group('SensitivityClassifier', () {
    const c = SensitivityClassifier();
    Set<SensitivityFlag> content(String text) => c
        .classify(
          text: text,
          sender: 'Mom',
          identityConfidence: 'high',
          contactKnown: true,
        )
        .flags;

    test('clean message from a known, identified contact has no flags', () {
      expect(content('Thanks, see you at the gym later!'), isEmpty);
      expect(
        c
            .classify(
              text: 'Thanks, see you at the gym later!',
              sender: 'Mom',
              identityConfidence: 'high',
              contactKnown: true,
            )
            .risk,
        'low',
      );
    });

    test('flags OTP / verification codes', () {
      expect(content('Your OTP is 482913'), contains(SensitivityFlag.otp));
      expect(
        content('482913 is your verification code. Do not share it.'),
        contains(SensitivityFlag.otp),
      );
      expect(content('Use code 5521 to log in'), contains(SensitivityFlag.otp));
    });

    test('flags credentials', () {
      expect(
        content('the wifi password is hunter22'),
        contains(SensitivityFlag.credentials),
      );
      expect(
        content('send me your PIN'),
        contains(SensitivityFlag.credentials),
      );
    });

    test('flags money / payments', () {
      for (final t in [
        'Please send ₹500 via UPI',
        'Can you transfer the money today',
        'Invoice attached',
        'I paid \$20 for the tickets',
        'loan EMI is due',
        'Rs 2000 for the cab',
      ]) {
        expect(content(t), contains(SensitivityFlag.money), reason: t);
      }
    });

    test('flags legal, medical, crisis and commitments', () {
      expect(
        content('Need you to sign the contract'),
        contains(SensitivityFlag.legal),
      );
      expect(
        content('The doctor gave me a new prescription'),
        contains(SensitivityFlag.medical),
      );
      expect(
        content('Going to the hospital, symptoms got worse'),
        contains(SensitivityFlag.medical),
      );
      expect(content('I want to die'), contains(SensitivityFlag.crisis));
      expect(
        content('emergency, call me now'),
        contains(SensitivityFlag.crisis),
      );
      expect(
        content('Can you come on Saturday? Please confirm'),
        contains(SensitivityFlag.commitment),
      );
      expect(
        content('I promise I will pay you back'),
        containsAll([SensitivityFlag.commitment, SensitivityFlag.money]),
      );
    });

    test('flags unknown sender, ambiguous text, group and low identity', () {
      final r = c.classify(
        text: 'ok',
        sender: '+91 98765 43210',
        isGroup: true,
        identityConfidence: 'low',
      );
      expect(
        r.flags,
        containsAll([
          SensitivityFlag.unknownSender,
          SensitivityFlag.ambiguous,
          SensitivityFlag.groupChat,
          SensitivityFlag.lowIdentity,
        ]),
      );
      expect(r.risk, 'high');
      expect(
        c
            .classify(
              text: '👍',
              sender: 'Mom',
              identityConfidence: 'high',
              contactKnown: true,
            )
            .flags,
        contains(SensitivityFlag.ambiguous),
      );
    });

    test('csv round trip', () {
      const r = SensitivityResult({SensitivityFlag.money, SensitivityFlag.otp});
      expect(r.csv, 'money,otp');
      expect(SensitivityResult.parseCsv(r.csv), r.flags);
      expect(SensitivityResult.parseCsv(null), isEmpty);
    });
  });

  group('ReplyPolicyEngine — restricted auto-reply matrix', () {
    const engine = ReplyPolicyEngine();

    PolicyInput input({
      AssistantMode global = AssistantMode.restrictedAuto,
      bool kill = false,
      String pkg = _sms,
      bool appEnabled = true,
      AssistantMode appMode = AssistantMode.restrictedAuto,
      bool appBlocked = false,
      String rule = 'approved',
      String contactIdentity = 'high',
      int maxAuto = 2,
      bool noContact = false,
      bool group = false,
      String identity = 'high',
      Set<SensitivityFlag> flags = const {},
      DraftCandidate? draft = const DraftCandidate(
        text: 'Got it, thanks!',
        category: ReplyCategory.acknowledgement,
        confidence: 0.95,
      ),
      int sentConv = 0,
      int sentDay = 0,
      int minute = 10 * 60,
      bool reply = true,
      PolicyLimits limits = const PolicyLimits(),
    }) => PolicyInput(
      globalMode: global,
      killSwitch: kill,
      app: AppPolicy(
        packageName: pkg,
        enabled: appEnabled,
        mode: appMode,
        autoSendBlocked: appBlocked,
      ),
      contact: noContact
          ? null
          : ContactPolicy(
              rule: rule,
              identityConfidence: contactIdentity,
              maxAutoRepliesPerDay: maxAuto,
            ),
      isGroup: group,
      identityConfidence: identity,
      flags: flags,
      limits: limits,
      minuteOfDay: minute,
      hasReplyAction: reply,
      draft: draft,
      sentTodayForConversation: sentConv,
      sentToday: sentDay,
    );

    void expectApproval(PolicyInput i, String reason) {
      final d = engine.decide(i);
      expect(d.action, PolicyAction.requestApproval, reason: reason);
      expect(
        d.reasons.any((r) => r.startsWith(reason)),
        isTrue,
        reason: '${d.reasons}',
      );
    }

    test('all conditions met on an SMS app → auto_send_allowed', () {
      final d = engine.decide(input());
      expect(d.action, PolicyAction.autoSendAllowed, reason: '$d');
    });

    test('WhatsApp is hard-blocked in code even if settings say not', () {
      expectApproval(input(pkg: 'com.whatsapp'), 'app_auto_send_blocked');
      expectApproval(input(pkg: 'com.whatsapp.w4b'), 'app_auto_send_blocked');
      expectApproval(input(appBlocked: true), 'app_auto_send_blocked');
      // Unknown / unverified apps are blocked by default.
      expectApproval(
        input(pkg: 'org.telegram.messenger'),
        'app_auto_send_blocked',
      );
      expectApproval(input(pkg: 'com.example.chat'), 'app_auto_send_blocked');
    });

    test('sensitive flags → approval', () {
      for (final f in SensitivityFlag.values) {
        expectApproval(input(flags: {f}), 'sensitive:');
      }
    });

    test('caps, quiet hours, confidence, identity, group, length', () {
      expectApproval(input(sentConv: 2), 'conversation_cap_reached');
      expectApproval(input(maxAuto: 0), 'conversation_cap_reached');
      expectApproval(input(sentDay: 10), 'daily_cap_reached');
      expectApproval(input(minute: 23 * 60), 'quiet_hours');
      expectApproval(input(minute: 6 * 60 + 59), 'quiet_hours');
      expectApproval(
        input(
          draft: const DraftCandidate(
            text: 'ok!',
            category: ReplyCategory.acknowledgement,
            confidence: 0.5,
          ),
        ),
        'low_confidence',
      );
      expectApproval(input(identity: 'low'), 'low_identity_confidence');
      expectApproval(input(contactIdentity: 'low'), 'low_identity_confidence');
      expectApproval(input(group: true), 'group_chat');
      expectApproval(
        input(
          draft: DraftCandidate(
            text: 'x' * 200,
            category: ReplyCategory.acknowledgement,
            confidence: 0.99,
          ),
        ),
        'too_long',
      );
      expectApproval(
        input(
          draft: const DraftCandidate(
            text: 'See you at 6',
            category: ReplyCategory.scheduling,
            confidence: 0.99,
          ),
        ),
        'category_not_permitted',
      );
      expectApproval(input(rule: 'neutral'), 'contact_not_approved');
      expectApproval(input(noContact: true), 'contact_not_approved');
      expectApproval(input(reply: false), 'no_reply_action');
      expectApproval(input(draft: null), 'no_draft');
      expectApproval(
        input(
          draft: const DraftCandidate(
            text: 'Sure',
            category: ReplyCategory.acknowledgement,
            confidence: 0.99,
            needsHuman: true,
          ),
        ),
        'drafter_needs_human',
      );
    });

    test('ignore rules come first', () {
      expect(engine.decide(input(kill: true)).action, PolicyAction.ignore);
      expect(
        engine.decide(input(global: AssistantMode.disabled)).action,
        PolicyAction.ignore,
      );
      expect(engine.decide(input(appEnabled: false)).reasons, [
        'app_not_enabled',
      ]);
      expect(
        engine.decide(input(appMode: AssistantMode.disabled)).action,
        PolicyAction.ignore,
      );
      expect(engine.decide(input(rule: 'blocked')).reasons, [
        'contact_blocked',
      ]);
      expect(engine.decide(input(group: true, rule: 'neutral')).reasons, [
        'group_not_approved',
      ]);
    });

    test('modes map to actions and the global mode caps the app mode', () {
      expect(
        engine.decide(input(global: AssistantMode.observe)).action,
        PolicyAction.observeOnly,
      );
      expect(
        engine.decide(input(global: AssistantMode.draft)).action,
        PolicyAction.saveDraft,
      );
      expect(
        engine.decide(input(global: AssistantMode.approval)).action,
        PolicyAction.requestApproval,
      );
      expect(
        engine.decide(input(appMode: AssistantMode.draft)).action,
        PolicyAction.saveDraft,
      );
    });

    test('quiet hours wrap midnight and can be disabled', () {
      const l = PolicyLimits(quietStartMinutes: 1320, quietEndMinutes: 420);
      expect(l.inQuietHours(1330), isTrue);
      expect(l.inQuietHours(100), isTrue);
      expect(l.inQuietHours(420), isFalse);
      expect(l.inQuietHours(800), isFalse);
      const none = PolicyLimits(quietStartMinutes: 0, quietEndMinutes: 0);
      expect(none.inQuietHours(100), isFalse);
    });

    test('explanations exist for every reason', () {
      for (final r in [
        'app_auto_send_blocked',
        'quiet_hours',
        'sensitive:money+otp',
      ]) {
        expect(explainReason(r), isNot(r));
      }
    });
  });

  group('Draft status transitions', () {
    test('terminal states cannot be re-sent', () {
      expect(
        DraftStatus.canTransition(DraftStatus.handedOff, DraftStatus.sending),
        isFalse,
      );
      expect(
        DraftStatus.canTransition(DraftStatus.failed, DraftStatus.sending),
        isFalse,
      );
      expect(
        DraftStatus.canTransition(DraftStatus.approved, DraftStatus.sending),
        isTrue,
      );
      expect(
        DraftStatus.canTransition(DraftStatus.sending, DraftStatus.handedOff),
        isTrue,
      );
      expect(
        DraftStatus.canTransition(DraftStatus.rejected, DraftStatus.approved),
        isFalse,
      );
    });
  });

  group('hashing', () {
    test('FNV-1a 64 known vectors (mirrored in Kotlin)', () {
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');
      expect(fnv1a64Hex('foobar'), '85944171f73967e8');
    });

    test('dedupe hash rounds post time to the second', () {
      final a = dedupeHashFor(
        packageName: 'p',
        conversationKey: 'c',
        text: 't',
        postedAt: DateTime.fromMillisecondsSinceEpoch(1000100, isUtc: true),
      );
      final b = dedupeHashFor(
        packageName: 'p',
        conversationKey: 'c',
        text: 't',
        postedAt: DateTime.fromMillisecondsSinceEpoch(1000900, isUtc: true),
      );
      expect(a, b);
      expect(idempotencyKeyFor(a, 'd1'), isNot(idempotencyKeyFor(a, 'd2')));
      expect(conversationRef('Mom'), isNot(contains('Mom')));
    });
  });

  group('BriefingBuilder', () {
    final now = DateTime(2026, 10, 25, 9);

    test('reports remaining amounts and is honest about missing data', () {
      final lines = const BriefingBuilder().build(
        BriefingInputs(
          now: now,
          steps: 4000,
          stepGoal: 10000,
          caloriesConsumed: 500,
          calorieTarget: 2000,
          proteinConsumed: 50,
          proteinTarget: 150,
          waterMl: 1000,
          waterGoalMl: 3000,
          calendar: const CalendarReadResult.notConnected(),
          pendingDrafts: 2,
          habitsDue: 3,
          habitsRemaining: 1,
        ),
      );
      final text = lines.map((l) => l.text).join('\n');
      expect(text, contains('6,000 steps to go'));
      expect(text, contains('1,500 kcal remaining'));
      expect(text, contains('100 g protein remaining'));
      expect(text, contains('2 L water to go'));
      expect(text, contains('Calendar not connected'));
      expect(text, contains('2 replies waiting'));
      expect(text, contains('1 habit left'));
    });

    test('no steps data is not shown as zero', () {
      final lines = const BriefingBuilder().build(BriefingInputs(now: now));
      expect(lines.first.text, 'Steps: no data yet today');
    });

    test('next calendar events and unanswered heuristic label', () {
      final lines = const BriefingBuilder().build(
        BriefingInputs(
          now: now,
          calendar: CalendarReadResult.connected([
            CalendarEventView(
              id: '1',
              calendarId: 'c',
              title: 'Standup',
              start: DateTime(2026, 10, 25, 10),
              end: DateTime(2026, 10, 25, 10, 15),
            ),
          ]),
          unanswered: [
            UnansweredConversation(
              title: 'Mom',
              appLabel: 'WhatsApp',
              lastAt: DateTime(2026, 10, 25, 6),
            ),
          ],
        ),
      );
      final cal = lines.firstWhere((l) => l.kind == BriefingKind.calendar);
      expect(cal.text, contains('Standup'));
      final un = lines.firstWhere((l) => l.kind == BriefingKind.unanswered);
      expect(un.text, contains('Mom'));
      expect(un.note, contains('Heuristic'));
    });
  });

  group('CapturedEvent parsing', () {
    test('parses native JSON and rejects malformed input', () {
      final e = CapturedEvent.tryParse(
        '{"key":"k","packageName":"com.whatsapp","conversationKey":"s1",'
        '"identityConfidence":"high","title":"Mom","isGroup":false,'
        '"sender":"Mom","text":"hi there","postTime":1761379200000,'
        '"hasReplyAction":true,"dedupeHash":"abc"}',
      );
      expect(e, isNotNull);
      expect(e!.identityConfidence, 'high');
      expect(e.hasReplyAction, isTrue);
      expect(CapturedEvent.tryParse('not json'), isNull);
      expect(CapturedEvent.tryParse('{"packageName":"x"}'), isNull);
    });
  });
}
