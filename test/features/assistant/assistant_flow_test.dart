import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/ingestion_service.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/application/reply_drafter.dart';
import 'package:athlete_os/features/assistant/data/assistant_platform.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:athlete_os/features/assistant/domain/safe_log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'assistant_test_utils.dart';

void main() {
  late AppDatabase db;
  late FakeAssistantPlatform fake;
  late ProviderContainer c;
  late List<String> logs;
  late void Function(String) originalSink;

  setUp(() {
    db = newTestDb();
    fake = FakeAssistantPlatform(
      listenerEnabled: true,
      listenerConnected: true,
    );
    logs = [];
    originalSink = safeLogSink;
    safeLogSink = logs.add;
  });

  tearDown(() async {
    safeLogSink = originalSink;
    c.dispose();
    await fake.dispose();
    await db.close();
  });

  ProviderContainer make({ReplyDrafter? drafter, List<String>? clipboard}) =>
      c = assistantContainer(db, fake, drafter: drafter, clipboard: clipboard);

  Future<IngestSummary> ingest(List<CapturedEvent> events) =>
      c.read(ingestionServiceProvider).ingest(events);

  Future<List<ReplyDraft>> drafts() =>
      c.read(assistantRepositoryProvider).allDrafts();

  Future<int> capturedCount() =>
      c.read(assistantRepositoryProvider).capturedCount();

  group('ingestion', () {
    test(
      'apps that are not enabled are ignored and nothing is stored',
      () async {
        make();
        final s = await ingest([ev(pkg: 'com.example.chat')]);
        expect(s.ignored, 1);
        expect(await capturedCount(), 0);
        expect(await drafts(), isEmpty);
        final audit = await c.read(assistantRepositoryProvider).auditRows();
        expect(audit.single.action, AuditAction.ignore);
        expect(audit.single.detail, contains('app_not_enabled'));
      },
    );

    test('defaults: global Draft mode, every app disabled', () async {
      make();
      final s = await c.read(assistantRepositoryProvider).settings();
      expect(s.mode, AssistantMode.draft);
      expect(s.killSwitch, isFalse);
      expect(s.aiConsent, isFalse);
      final cfg = await c.read(assistantControllerProvider).syncNativeConfig();
      expect(cfg.enabledPackages, isEmpty);
    });

    test('duplicate events produce one row and one draft', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      final e = ev();
      final s1 = await ingest([e, e]);
      final s2 = await ingest([e]);
      expect(s1.stored, 1);
      expect(s1.duplicates, 1);
      expect(s2.duplicates, 1);
      expect(await capturedCount(), 1);
      final d = await drafts();
      expect(d, hasLength(1));
      expect(d.single.status, DraftStatus.draft);
    });

    test(
      'a second message in the same chat refreshes the open draft',
      () async {
        make();
        await enableApp(c, whatsapp, label: 'WhatsApp');
        await ingest([ev(text: 'Hi')]);
        await ingest([ev(text: 'Are you coming at 7?', key: 'k2')]);
        expect(await capturedCount(), 2);
        expect(await drafts(), hasLength(1));
      },
    );

    test('Draft mode never sends, even with an AI draft', () async {
      final drafter = FakeDrafter();
      make(drafter: drafter);
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([ev(text: 'Thanks for the help today')]);
      final d = (await drafts()).single;
      expect(drafter.requests, hasLength(1));
      expect(d.draftText, 'Got it, thanks!');
      expect(d.status, DraftStatus.draft);
      expect(fake.sendCalls, isEmpty);
    });

    test('observe mode stores but does not draft', () async {
      make();
      await enableApp(
        c,
        whatsapp,
        mode: AssistantMode.observe,
        label: 'WhatsApp',
      );
      await ingest([ev()]);
      expect(await capturedCount(), 1);
      expect(await drafts(), isEmpty);
    });

    test('group chats are ignored unless approved', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([ev(conv: 'g1', group: true, title: 'Gym buddies')]);
      expect(await capturedCount(), 0);
      // The group name (no message) is kept so it can be approved.
      final rules = await c
          .read(assistantRepositoryProvider)
          .watchContacts()
          .first;
      expect(rules.single.isGroup, isTrue);
      await approveContact(c, whatsapp, 'g1', group: true);
      await ingest([
        ev(conv: 'g1', group: true, title: 'Gym buddies', text: 'Leg day?'),
      ]);
      expect(await capturedCount(), 1);
    });

    test('blocked contacts are ignored', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      final repo = c.read(assistantRepositoryProvider);
      final rule = await repo.ensureContact(
        packageName: whatsapp,
        conversationKey: 'spam',
        displayName: 'Spam',
        isGroup: false,
        identityConfidence: 'high',
      );
      await repo.updateContact(rule.id, rule: 'blocked');
      await ingest([ev(conv: 'spam')]);
      expect(await capturedCount(), 0);
    });

    test('drafter only sees this conversation within retention', () async {
      final drafter = FakeDrafter();
      make(drafter: drafter);
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([ev(conv: 'other', text: 'Other chat secret', key: 'o')]);
      await ingest([ev(text: 'Dinner at 8?')]);
      final req = drafter.requests.last;
      expect(req.messages.map((m) => m.text), ['Dinner at 8?']);
    });

    test('no AI without consent; OTP never goes to AI', () async {
      final drafter = FakeDrafter();
      make(drafter: drafter);
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await ingest([ev(text: 'Want to grab lunch?')]);
      expect(drafter.requests, isEmpty);
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([ev(conv: 'bank', text: 'Your OTP is 123456', key: 'b')]);
      expect(drafter.requests, isEmpty);
    });
  });

  group('restricted auto-reply', () {
    Future<void> setupSms({int maxAuto = 2}) async {
      await enableApp(
        c,
        sms,
        mode: AssistantMode.restrictedAuto,
        global: AssistantMode.restrictedAuto,
        allowAi: true,
        label: 'Messages',
      );
      await c.read(assistantControllerProvider).setAiConsent(true);
      await approveContact(c, sms, 'sms-1', maxAuto: maxAuto);
    }

    test('sends only when every rule passes (SMS, approved contact)', () async {
      make(drafter: FakeDrafter());
      await setupSms();
      await ingest([ev(pkg: sms, conv: 'sms-1', text: 'Thanks for today')]);
      expect(fake.sendCalls, hasLength(1));
      final d = (await drafts()).single;
      expect(d.status, DraftStatus.handedOff);
      expect(d.sendPolicy, 'restricted_auto');
      expect(d.deliveryDetail, contains('does not confirm delivery'));
    });

    test('sensitive messages require approval', () async {
      make(drafter: FakeDrafter());
      await setupSms();
      await ingest([
        ev(pkg: sms, conv: 'sms-1', text: 'Can you send ₹500 on UPI?'),
      ]);
      expect(fake.sendCalls, isEmpty);
      final d = (await drafts()).single;
      expect(d.status, DraftStatus.pendingApproval);
      expect(d.risk, 'high');
      expect(d.riskFlags, contains('money'));
      // Content-free approval notification.
      expect(fake.posted.single.body, isNot(contains('500')));
    });

    test('WhatsApp can never auto-send, whatever the settings', () async {
      make(drafter: FakeDrafter());
      await enableApp(
        c,
        whatsapp,
        mode: AssistantMode.restrictedAuto,
        global: AssistantMode.restrictedAuto,
        allowAi: true,
        label: 'WhatsApp',
      );
      await c.read(assistantControllerProvider).setAiConsent(true);
      await approveContact(c, whatsapp, 'shortcut-mom');
      final app = await c.read(assistantRepositoryProvider).app(whatsapp);
      expect(app!.autoSendBlocked, isTrue);
      expect(app.mode, AssistantMode.approval.key);
      await ingest([ev(text: 'Thanks for today')]);
      expect(fake.sendCalls, isEmpty);
      expect((await drafts()).single.status, DraftStatus.pendingApproval);
    });

    test('daily per-conversation cap is enforced', () async {
      make(drafter: FakeDrafter());
      await setupSms(maxAuto: 1);
      await ingest([ev(pkg: sms, conv: 'sms-1', text: 'Thanks!! see ya')]);
      await ingest([
        ev(pkg: sms, conv: 'sms-1', text: 'Great job today', key: 'k2'),
      ]);
      expect(fake.sendCalls, hasLength(1));
      final open = (await drafts()).where(
        (d) => d.status == DraftStatus.pendingApproval,
      );
      expect(open, hasLength(1));
    });

    test('low drafter confidence downgrades to approval', () async {
      make(
        drafter: FakeDrafter(
          const DraftResult(
            text: 'Sure',
            category: ReplyCategory.acknowledgement,
            confidence: 0.4,
          ),
        ),
      );
      await setupSms();
      await ingest([ev(pkg: sms, conv: 'sms-1', text: 'Thanks for today')]);
      expect(fake.sendCalls, isEmpty);
    });
  });

  group('sending', () {
    Future<ReplyDraft> pendingDraft({bool reply = true}) async {
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([ev(reply: reply)]);
      final d = (await drafts()).single;
      await c.read(replyServiceProvider).editDraft(d.id, 'Yes, 8pm works');
      return d;
    }

    test('user tap hands off once; a second tap never re-sends', () async {
      make();
      final d = await pendingDraft();
      final svc = c.read(replyServiceProvider);
      final r1 = await svc.approveAndSend(d.id);
      expect(r1.status, DraftStatus.handedOff);
      expect(r1.message, contains('does not confirm delivery'));
      final r2 = await svc.approveAndSend(d.id);
      expect(r2.status, 'refused');
      expect(fake.sendCalls, hasLength(1));
      expect(fake.sendCalls.single.text, 'Yes, 8pm works');
      final after = (await drafts()).single;
      expect(after.status, DraftStatus.handedOff);
      expect(after.idempotencyKey, fake.sendCalls.single.idempotencyKey);
    });

    test('notification gone → failed with a clear message', () async {
      make();
      fake.sendResults.add(
        const SendReplyResult(
          status: 'failed',
          code: 'notification_gone',
          detail: 'The original notification is no longer showing.',
        ),
      );
      final d = await pendingDraft();
      final r = await c.read(replyServiceProvider).approveAndSend(d.id);
      expect(r.status, DraftStatus.failed);
      final after = (await drafts()).single;
      expect(after.status, DraftStatus.failed);
      expect(after.deliveryDetail, contains('no longer showing'));
    });

    test('no reply action → unsupported, Copy & open explained', () async {
      final clipboard = <String>[];
      make(clipboard: clipboard);
      final d = await pendingDraft(reply: false);
      final r = await c.read(replyServiceProvider).approveAndSend(d.id);
      expect(r.status, DraftStatus.unsupported);
      expect(r.message, contains('Copy & open'));
      expect(fake.sendCalls, isEmpty);
    });

    test('Copy & open copies the draft and opens the app', () async {
      final clipboard = <String>[];
      make(clipboard: clipboard);
      final d = await pendingDraft(reply: false);
      final r = await c.read(replyServiceProvider).copyAndOpen(d.id);
      expect(clipboard, ['Yes, 8pm works']);
      expect(fake.openedApps, [whatsapp]);
      expect(r.status, DraftStatus.unsupported);
      expect((await drafts()).single.deliveryDetail, contains('yourself'));
    });

    test('listener not connected → exactly one retry', () async {
      make();
      fake.sendResults
        ..add(
          const SendReplyResult(
            status: 'failed',
            code: 'listener_not_connected',
            detail: 'not connected',
          ),
        )
        ..add(
          const SendReplyResult(
            status: 'failed',
            code: 'listener_not_connected',
            detail: 'Listener not connected.',
          ),
        );
      final d = await pendingDraft();
      final r = await c.read(replyServiceProvider).approveAndSend(d.id);
      expect(fake.sendCalls, hasLength(2));
      expect(r.status, DraftStatus.failed);
    });

    test('reject closes the draft without sending', () async {
      make();
      final d = await pendingDraft();
      await c.read(replyServiceProvider).reject(d.id);
      expect((await drafts()).single.status, DraftStatus.rejected);
      final r = await c.read(replyServiceProvider).approveAndSend(d.id);
      expect(r.status, 'refused');
      expect(fake.sendCalls, isEmpty);
    });
  });

  group('kill switch', () {
    test(
      'stops capture, drafting and sending; native config updated',
      () async {
        make(drafter: FakeDrafter());
        await enableApp(c, whatsapp, label: 'WhatsApp');
        await ingest([ev()]);
        final d = (await drafts()).single;
        await c.read(replyServiceProvider).editDraft(d.id, 'On my way');

        await c.read(assistantControllerProvider).setKillSwitch(true);
        expect(fake.lastConfig!.killSwitch, isTrue);
        expect(fake.lastConfig!.enabledPackages, isEmpty);
        expect(fake.serviceRunning, isFalse);

        final s = await ingest([ev(text: 'New message', key: 'n')]);
        expect(s.killed, 1);
        expect(await capturedCount(), 1);
        expect(await drafts(), hasLength(1));

        final r = await c.read(replyServiceProvider).approveAndSend(d.id);
        expect(r.status, 'refused');
        expect(fake.sendCalls, isEmpty);

        await c.read(assistantControllerProvider).setKillSwitch(false);
        expect(fake.lastConfig!.killSwitch, isFalse);
        expect(fake.lastConfig!.enabledPackages, [whatsapp]);
      },
    );
  });

  group('retention & deletion', () {
    test('expired messages are purged; delete-all wipes content', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([
        ev(at: testNow.subtract(const Duration(days: 8)), key: 'old'),
        ev(text: 'Fresh one', key: 'new'),
      ]);
      expect(await capturedCount(), 2);
      final purged = await c.read(ingestionServiceProvider).purge();
      expect(purged, 1);
      expect(await capturedCount(), 1);

      await c.read(assistantControllerProvider).deleteAllCaptured();
      expect(await capturedCount(), 0);
      expect((await drafts()).every((d) => d.draftText.isEmpty), isTrue);
      expect(fake.clearQueueCalls, 1);
    });

    test('drain ingests queued events', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      fake.queue.addAll([ev(), ev()]);
      final s = await c.read(ingestionServiceProvider).drainAndIngest();
      expect(s.stored, 1);
      expect(s.duplicates, 1);
      expect(fake.queue, isEmpty);
    });
  });

  group('logging hygiene', () {
    test('no message bodies or credentials reach logs or the audit', () async {
      const secret = 'my password is Hunter2Secret and OTP 774411';
      make(drafter: FakeDrafter());
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([ev(text: secret, title: 'Priya Sharma', sender: 'Priya')]);
      final d = (await drafts()).single;
      await c
          .read(replyServiceProvider)
          .editDraft(d.id, 'Reply with sk-ant-abcdefghijklmnop');
      await c.read(replyServiceProvider).approveAndSend(d.id);

      safeLog('test_event', {
        'code': secret,
        'body': 'Hunter2Secret',
        'status': 'ok',
      });

      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains('Hunter2Secret')));
        expect(line, isNot(contains('774411')));
        expect(line, isNot(contains('Priya')));
        expect(line, isNot(contains('sk-ant')));
      }
      final audit = await c.read(assistantRepositoryProvider).auditRows();
      for (final a in audit) {
        final row =
            '${a.action} ${a.packageName} ${a.conversationKey} '
            '${a.detail}';
        expect(row, isNot(contains('Hunter2Secret')));
        expect(row, isNot(contains('Priya')));
        expect(row, isNot(contains('shortcut-mom')));
        expect(row, isNot(contains('sk-ant')));
      }
    });
  });
}
