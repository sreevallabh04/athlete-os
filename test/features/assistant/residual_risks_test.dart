// Regression tests for residual risks: lock-screen privacy of assistant
// notifications, a notification Stop that must persist, and AI redrafts that
// must never clobber text the user typed.
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/application/reply_drafter.dart';
import 'package:athlete_os/features/assistant/application/reply_service.dart';
import 'package:athlete_os/features/assistant/data/assistant_platform.dart';
import 'package:athlete_os/features/assistant/data/assistant_repository.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:athlete_os/features/assistant/domain/assistant_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'assistant_test_utils.dart';

/// Drafter that can run a side effect (e.g. "the user saves an edit") while
/// the AI request is in flight.
class _InFlightDrafter extends FakeDrafter {
  _InFlightDrafter(super.result);
  Future<void> Function()? duringDraft;

  @override
  Future<DraftResult> draft(DraftRequest request) async {
    final r = await super.draft(request);
    await duringDraft?.call();
    return r;
  }
}

const _aiText = DraftResult(
  text: 'Yes, see you at 7!',
  category: ReplyCategory.acknowledgement,
  confidence: 0.95,
);
const _newAiText = DraftResult(
  text: 'Running late, 7:30?',
  category: ReplyCategory.acknowledgement,
  confidence: 0.95,
);

void main() {
  late AppDatabase db;
  late FakeAssistantPlatform fake;
  late ProviderContainer c;

  setUp(() {
    db = newTestDb();
    fake = FakeAssistantPlatform(
      listenerEnabled: true,
      listenerConnected: true,
    );
  });

  tearDown(() async {
    c.dispose();
    await fake.dispose();
    await db.close();
  });

  ProviderContainer make({ReplyDrafter? drafter}) =>
      c = assistantContainer(db, fake, drafter: drafter);

  AssistantRepository repo() => c.read(assistantRepositoryProvider);
  ReplyService replies() => c.read(replyServiceProvider);

  Future<void> ingest(List<CapturedEvent> events) =>
      c.read(ingestionServiceProvider).ingest(events);

  Future<ReplyDraft> onlyDraft() async => (await repo().allDrafts()).single;

  Future<List<String>> auditDetails() async => [
    for (final a in await repo().auditRows()) a.detail ?? '',
  ];

  group('lock-screen privacy', () {
    test('morning briefing is private with a generic public version', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([ev()]); // "Mom" is now an unanswered conversation.
      await c
          .read(assistantControllerProvider)
          .setBriefing(
            const BriefingSettings(
              morningEnabled: true,
              morningMinutes: 8 * 60,
            ),
          );
      await c.read(briefingServiceProvider).maybePostScheduled();

      final n = fake.posted.single;
      expect(n.visibility, LockScreenVisibility.private);
      expect(n.publicTitle, AssistantLockScreenCopy.briefingTitle);
      expect(n.publicBody, AssistantLockScreenCopy.body);
      for (final public in [n.publicTitle!, n.publicBody!]) {
        expect(public, isNot(contains('Mom')));
        expect(public, isNot(contains(RegExp(r'\d'))));
      }
    });

    test('evening review is private with a generic public version', () async {
      make();
      await c
          .read(assistantControllerProvider)
          .setBriefing(
            const BriefingSettings(
              eveningEnabled: true,
              eveningMinutes: 8 * 60,
            ),
          );
      await c.read(briefingServiceProvider).maybePostScheduled();
      final n = fake.posted.single;
      expect(n.visibility, LockScreenVisibility.private);
      expect(n.publicTitle, AssistantLockScreenCopy.reviewTitle);
    });

    test('approval notification is private and its public version names '
        'neither the app nor the contact', () async {
      make();
      await enableApp(
        c,
        whatsapp,
        mode: AssistantMode.approval,
        global: AssistantMode.approval,
        label: 'WhatsApp',
      );
      await ingest([ev()]);
      final n = fake.posted.single;
      expect(n.visibility, LockScreenVisibility.private);
      expect(n.publicTitle, AssistantLockScreenCopy.approvalTitle);
      expect(n.publicTitle, isNot(contains('WhatsApp')));
      expect(n.publicBody, isNot(contains('WhatsApp')));
      expect(n.publicTitle, isNot(contains('Mom')));
    });

    test('the platform default is private (fail closed)', () async {
      await fake.postNotification(1, 'Title', 'Body');
      expect(fake.posted.single.visibility, LockScreenVisibility.private);
    });
  });

  group('Assistant mode Stop', () {
    test('Stop on the notification persists "off": no restart on the next '
        'launch', () async {
      make();
      final ctl = c.read(assistantControllerProvider);
      await ctl.setServiceEnabled(true);
      expect(fake.serviceRunning, isTrue);

      fake.tapServiceStop();
      // Next launch.
      expect(await ctl.restoreService(), isFalse);
      expect(fake.serviceRunning, isFalse);
      expect((await repo().settings()).serviceEnabled, isFalse);
      expect(await auditDetails(), contains(contains('notification_stop')));

      // And the launch after that.
      expect(await ctl.restoreService(), isFalse);
      expect(fake.serviceRunning, isFalse);
    });

    test('without a Stop tap, an enabled service is restored', () async {
      make();
      final ctl = c.read(assistantControllerProvider);
      await ctl.setServiceEnabled(true);
      fake.serviceRunning = false; // process was killed
      expect(await ctl.restoreService(), isTrue);
      expect(fake.serviceRunning, isTrue);
    });

    test('kill switch keeps the preference; turning it off restores the '
        'service', () async {
      make();
      final ctl = c.read(assistantControllerProvider);
      await ctl.setServiceEnabled(true);
      await ctl.setKillSwitch(true);
      expect(fake.serviceRunning, isFalse);
      expect((await repo().settings()).serviceEnabled, isTrue);
      expect(await ctl.restoreService(), isFalse);
      await ctl.setKillSwitch(false);
      expect(fake.serviceRunning, isTrue);
    });

    test('a Stop tap wins over the kill switch being turned off', () async {
      make();
      final ctl = c.read(assistantControllerProvider);
      await ctl.setServiceEnabled(true);
      fake.tapServiceStop();
      await ctl.setKillSwitch(true);
      await ctl.setKillSwitch(false);
      expect(fake.serviceRunning, isFalse);
      expect((await repo().settings()).serviceEnabled, isFalse);
    });

    test(
      'turning Assistant mode back on in the app works after a Stop',
      () async {
        make();
        final ctl = c.read(assistantControllerProvider);
        await ctl.setServiceEnabled(true);
        fake.tapServiceStop();
        await ctl.restoreService();
        await ctl.setServiceEnabled(true);
        expect(fake.serviceRunning, isTrue);
        fake.serviceRunning = false;
        expect(await ctl.restoreService(), isTrue);
      },
    );
  });

  group('AI redraft never clobbers user text', () {
    Future<void> aiOn() async {
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
    }

    test('a new message keeps the user-edited draft and does not call the '
        'AI', () async {
      final drafter = FakeDrafter(_aiText);
      make(drafter: drafter);
      await aiOn();
      await ingest([ev(text: 'Dinner at 7?')]);
      final d = await onlyDraft();
      expect(d.draftText, _aiText.text);
      expect(d.isUserAuthored, isFalse);

      await replies().editDraft(d.id, 'Yes! Bringing dessert');
      expect((await onlyDraft()).isUserAuthored, isTrue);

      drafter.result = _newAiText;
      await ingest([ev(text: 'Or 7:30?', key: 'k2')]);
      final after = await onlyDraft();
      expect(after.id, d.id);
      expect(after.draftText, 'Yes! Bringing dessert');
      expect(drafter.requests, hasLength(1));
      expect(await auditDetails(), contains('ai_draft_skipped;user_edited'));
    });

    test('an untouched AI draft is still refreshed by a new message', () async {
      final drafter = FakeDrafter(_aiText);
      make(drafter: drafter);
      await aiOn();
      await ingest([ev(text: 'Dinner at 7?')]);
      drafter.result = _newAiText;
      await ingest([ev(text: 'Or 7:30?', key: 'k2')]);
      expect((await onlyDraft()).draftText, _newAiText.text);
      expect(drafter.requests, hasLength(2));
    });

    test('an edit saved while the AI is drafting wins', () async {
      final drafter = _InFlightDrafter(_aiText);
      make(drafter: drafter);
      await aiOn();
      await ingest([ev(text: 'Dinner at 7?')]);
      final d = await onlyDraft();

      drafter
        ..result = _newAiText
        ..duringDraft = () => replies().editDraft(d.id, 'Typed by me');
      await ingest([ev(text: 'Or 7:30?', key: 'k2')]);
      expect((await onlyDraft()).draftText, 'Typed by me');
      expect(
        await auditDetails(),
        contains('ai_draft_discarded;user_edited_or_closed'),
      );
    });

    test('explicit "Draft with AI" replaces the text the user saw, but not '
        'an edit saved meanwhile', () async {
      final drafter = _InFlightDrafter(_aiText);
      make(drafter: drafter);
      await aiOn();
      await ingest([ev(text: 'Dinner at 7?')]);
      final d = await onlyDraft();
      await replies().editDraft(d.id, 'draft one');

      drafter.result = _newAiText;
      final r = await replies().draftWithAi(d.id);
      expect(r.available, isTrue);
      expect((await onlyDraft()).draftText, _newAiText.text);

      await replies().editDraft(d.id, 'draft two');
      drafter.duringDraft = () => replies().editDraft(d.id, 'draft three');
      final r2 = await replies().draftWithAi(d.id);
      expect(r2.available, isFalse);
      expect(r2.needsHumanReason, ReplyService.keptUserDraftMessage);
      expect((await onlyDraft()).draftText, 'draft three');
    });

    test('restricted auto-reply never sends text the user typed while the AI '
        'was drafting', () async {
      final drafter = _InFlightDrafter(_aiText);
      make(drafter: drafter);
      await enableApp(
        c,
        sms,
        mode: AssistantMode.restrictedAuto,
        global: AssistantMode.restrictedAuto,
        allowAi: true,
        label: 'Messages',
      );
      await c.read(assistantControllerProvider).setAiConsent(true);
      await approveContact(c, sms, 'sms-1');
      drafter.duringDraft = () async {
        final d = await onlyDraft();
        await replies().editDraft(d.id, 'private words, not for sending');
      };
      await ingest([ev(pkg: sms, conv: 'sms-1', text: 'Thanks for today')]);
      expect(fake.sendCalls, isEmpty);
      final d = await onlyDraft();
      expect(d.draftText, 'private words, not for sending');
      expect(d.status, isNot(DraftStatus.handedOff));
    });
  });
}
