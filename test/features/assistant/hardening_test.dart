// Regression tests for the messaging-assistant hardening review:
// idempotency under races, code-level policy, AI data minimisation,
// retention and kill-switch robustness.
import 'dart:async';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/ingestion_service.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/application/reply_drafter.dart';
import 'package:athlete_os/features/assistant/application/reply_service.dart';
import 'package:athlete_os/features/assistant/bootstrap.dart';
import 'package:athlete_os/features/assistant/data/assistant_platform.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:athlete_os/features/assistant/domain/safe_log.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'assistant_test_utils.dart';

/// Platform whose sendReply / stopAssistantService can be made to throw.
class _FlakyPlatform extends FakeAssistantPlatform {
  _FlakyPlatform() : super(listenerEnabled: true, listenerConnected: true);

  bool throwOnSend = false;
  bool throwOnStopService = false;

  @override
  Future<SendReplyResult> sendReply({
    required String notificationKey,
    required String text,
    required String idempotencyKey,
  }) {
    if (throwOnSend) {
      sendCalls.add((
        key: notificationKey,
        text: text,
        idempotencyKey: idempotencyKey,
      ));
      throw PlatformException(code: 'boom');
    }
    return super.sendReply(
      notificationKey: notificationKey,
      text: text,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<bool> stopAssistantService() async {
    if (throwOnStopService) throw PlatformException(code: 'svc');
    return super.stopAssistantService();
  }
}

void main() {
  late AppDatabase db;
  late _FlakyPlatform fake;
  late ProviderContainer c;
  late void Function(String) originalSink;

  setUp(() {
    db = newTestDb();
    fake = _FlakyPlatform();
    originalSink = safeLogSink;
    safeLogSink = (_) {};
  });

  tearDown(() async {
    safeLogSink = originalSink;
    c.dispose();
    await fake.dispose();
    await db.close();
  });

  ProviderContainer make({ReplyDrafter? drafter}) =>
      c = assistantContainer(db, fake, drafter: drafter);

  Future<IngestSummary> ingest(List<CapturedEvent> events) =>
      c.read(ingestionServiceProvider).ingest(events);

  Future<List<ReplyDraft>> drafts() =>
      c.read(assistantRepositoryProvider).allDrafts();

  Future<List<AutomationAuditData>> auditOf(String action) async => [
    for (final a in await c.read(assistantRepositoryProvider).auditRows())
      if (a.action == action) a,
  ];

  group('idempotency', () {
    test('live event + native queue drain of the same notification → one '
        'row, one draft', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      final ingestion = c.read(ingestionServiceProvider)..start();
      final e = ev();
      fake.queue.add(e);
      fake.emit(e);
      final drained = ingestion.drainAndIngest();
      final drainedAgain = ingestion.drainAndIngest();
      await Future.wait([drained, drainedAgain]);
      await ingestion.ingest(const []); // flush the serialised chain
      expect(await c.read(assistantRepositoryProvider).capturedCount(), 1);
      expect(await drafts(), hasLength(1));
    });

    test('a re-posted notification (new key, same message) after the reply '
        'was handed off creates no second draft and no second send', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([ev()]);
      final d = (await drafts()).single;
      await c.read(replyServiceProvider).editDraft(d.id, 'See you at 8');
      final r = await c.read(replyServiceProvider).approveAndSend(d.id);
      expect(r.status, DraftStatus.handedOff);

      final s = await ingest([ev(key: '0|com.whatsapp|1|null|99999')]);
      expect(s.duplicates, 1);
      expect(await drafts(), hasLength(1));
      expect(fake.sendCalls, hasLength(1));
    });

    test(
      'approve tapped twice concurrently → one sendReply, one send audit',
      () async {
        make();
        await enableApp(c, whatsapp, label: 'WhatsApp');
        await ingest([ev()]);
        final d = (await drafts()).single;
        final svc = c.read(replyServiceProvider);
        await svc.editDraft(d.id, 'On my way');
        final results = await Future.wait([
          svc.approveAndSend(d.id),
          svc.approveAndSend(d.id),
        ]);
        expect(results.where((r) => r.ok), hasLength(1));
        expect(results.where((r) => r.status == 'refused'), hasLength(1));
        expect(fake.sendCalls, hasLength(1));
        expect(await auditOf(AuditAction.send), hasLength(1));
        expect(await auditOf(AuditAction.approve), hasLength(1));
      },
    );

    test('"Draft" tapped twice concurrently → one open draft', () async {
      make();
      await enableApp(
        c,
        whatsapp,
        mode: AssistantMode.observe,
        global: AssistantMode.observe,
        label: 'WhatsApp',
      );
      await ingest([ev()]);
      final row = (await db.select(db.capturedNotifications).get()).single;
      final svc = c.read(replyServiceProvider);
      final made = await Future.wait([
        svc.createManualDraft(row.id),
        svc.createManualDraft(row.id),
      ]);
      expect(await drafts(), hasLength(1));
      expect(made[0]!.id, made[1]!.id);
      expect(await auditOf(AuditAction.draft), hasLength(1));
    });

    test('a throwing platform send is recorded as failed, never as sent, and '
        'is not retried', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await ingest([ev()]);
      final d = (await drafts()).single;
      final svc = c.read(replyServiceProvider);
      await svc.editDraft(d.id, 'Yes');
      fake.throwOnSend = true;
      final r = await svc.approveAndSend(d.id);
      expect(r.status, DraftStatus.failed);
      final after = (await drafts()).single;
      expect(after.status, DraftStatus.failed);
      expect(after.sentAt, isNull);
      final row = (await db.select(db.capturedNotifications).get()).single;
      expect(row.status, isNot(CaptureStatus.replied));
      expect(await auditOf(AuditAction.sendFailed), hasLength(1));
      expect(await auditOf(AuditAction.send), isEmpty);

      fake.throwOnSend = false;
      expect((await svc.approveAndSend(d.id)).status, 'refused');
      expect(fake.sendCalls, hasLength(1));
    });

    test(
      'a send interrupted mid hand-off is closed as failed on recovery',
      () async {
        make();
        await enableApp(c, whatsapp, label: 'WhatsApp');
        await ingest([ev()]);
        final repo = c.read(assistantRepositoryProvider);
        final d = (await drafts()).single;
        await repo.transition(d.id, DraftStatus.approved, decided: true);
        await repo.transition(d.id, DraftStatus.sending);

        ReplyService at(Duration later) => ReplyService(
          repo: repo,
          platform: fake,
          drafter: const UnconfiguredReplyDrafter(),
          clock: FixedClock(testNow.add(later)),
        );
        // Still within the grace period: maybe genuinely in flight.
        expect(
          await at(const Duration(minutes: 1)).recoverInterruptedSends(),
          0,
        );
        expect(
          await at(const Duration(minutes: 10)).recoverInterruptedSends(),
          1,
        );
        final after = (await drafts()).single;
        expect(after.status, DraftStatus.failed);
        expect(after.sentAt, isNull);
        expect(fake.sendCalls, isEmpty);
      },
    );

    test('a failing batch does not wedge the ingestion chain', () async {
      make();
      safeLogSink = (_) => throw StateError('sink down');
      final first = ingest([ev(pkg: 'com.example.chat')]);
      await expectLater(first, throwsStateError);
      safeLogSink = (_) {};
      final second = await ingest([ev(pkg: 'com.example.chat', key: 'k2')])
          .timeout(const Duration(seconds: 5));
      expect(second.ignored, 1);
    });
  });

  group('policy', () {
    test('WhatsApp never auto-sends even if its DB row is tampered to '
        'restricted_auto / not blocked', () async {
      make(drafter: FakeDrafter());
      await enableApp(
        c,
        whatsapp,
        mode: AssistantMode.restrictedAuto,
        global: AssistantMode.restrictedAuto,
        allowAi: true,
        label: 'WhatsApp',
      );
      await (db.update(
        db.messagingAppSettings,
      )..where((a) => a.packageName.equals(whatsapp))).write(
        const MessagingAppSettingsCompanion(
          mode: Value('restricted_auto'),
          autoSendBlocked: Value(false),
        ),
      );
      await c.read(assistantControllerProvider).setAiConsent(true);
      await approveContact(c, whatsapp, 'shortcut-mom', maxAuto: 5);
      await ingest([ev(text: 'Thanks for today')]);
      expect(fake.sendCalls, isEmpty);
      expect((await drafts()).single.status, DraftStatus.pendingApproval);
      final classify = await auditOf(AuditAction.classify);
      expect(classify.single.detail, contains('app_auto_send_blocked'));
    });

    test(
      'a known group stays a group when a notification omits the flag',
      () async {
        make();
        await enableApp(c, whatsapp, label: 'WhatsApp');
        await c
            .read(assistantRepositoryProvider)
            .ensureContact(
              packageName: whatsapp,
              conversationKey: 'grp-1',
              displayName: 'Family',
              isGroup: true,
              identityConfidence: 'high',
            );
        final s = await ingest([ev(conv: 'grp-1')]);
        expect(s.ignored, 1);
        expect(await c.read(assistantRepositoryProvider).capturedCount(), 0);
        expect(await drafts(), isEmpty);
      },
    );

    test('kill switch: every native step runs even if one fails, and the '
        'failure is surfaced', () async {
      make();
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setServiceEnabled(true);
      fake.queue.add(ev());
      fake.throwOnStopService = true;
      await expectLater(
        c.read(assistantControllerProvider).setKillSwitch(true),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await c.read(assistantRepositoryProvider).settings()).killSwitch,
        isTrue,
      );
      expect(fake.lastConfig!.killSwitch, isTrue);
      expect(fake.clearQueueCalls, 1);
      expect(fake.queue, isEmpty);
      final audit = await auditOf(AuditAction.killSwitch);
      expect(audit.single.detail, 'on;partial');
      // Dart side refuses everything regardless.
      final s = await ingest([ev()]);
      expect(s.killed, 1);
    });

    test('only exact assistant routes may be opened from an intent', () {
      expect(isOpenableAssistantRoute('/assistant'), isTrue);
      expect(isOpenableAssistantRoute('/assistant/settings'), isTrue);
      expect(isOpenableAssistantRoute('/assistant/audit'), isTrue);
      expect(isOpenableAssistantRoute('/assistantx'), isFalse);
      expect(isOpenableAssistantRoute('/assistant/../coach'), isFalse);
      expect(isOpenableAssistantRoute('/coach?prompt=x'), isFalse);
    });
  });

  group('privacy', () {
    test('an earlier OTP in the same chat never reaches the drafter', () async {
      final drafter = FakeDrafter();
      make(drafter: drafter);
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([
        ev(
          text: 'Your OTP is 774411',
          key: 'a',
          at: testNow.subtract(const Duration(minutes: 5)),
        ),
      ]);
      expect(drafter.requests, isEmpty);
      await ingest([ev(text: 'Dinner at 8?', key: 'b')]);
      final texts = drafter.requests.last.messages.map((m) => m.text);
      expect(texts, ['Dinner at 8?']);
      expect(texts.join(), isNot(contains('774411')));
    });

    test('a shortened retention applies to already-captured messages (purge '
        'and AI context)', () async {
      final drafter = FakeDrafter();
      make(drafter: drafter);
      await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
      await c.read(assistantControllerProvider).setAiConsent(true);
      await ingest([
        ev(
          text: 'Old news from Tuesday',
          key: 'old',
          at: testNow.subtract(const Duration(days: 3)),
        ),
      ]);
      await c
          .read(assistantControllerProvider)
          .updateApp(whatsapp, appLabel: 'WhatsApp', retentionDays: 1);

      await ingest([ev(text: 'Dinner at 8?', key: 'new')]);
      expect(drafter.requests.last.messages.map((m) => m.text), [
        'Dinner at 8?',
      ]);

      final purged = await c.read(ingestionServiceProvider).purge();
      expect(purged, 1);
      final left = await db.select(db.capturedNotifications).get();
      expect(left.map((r) => r.body), ['Dinner at 8?']);
    });
  });

  testWidgets('bootstrap still starts live ingestion when the native config '
      'call hangs', (tester) async {
    await tester.runAsync(() async {
      final hanging = _HangingConfigPlatform();
      final container = ProviderContainer(
        overrides: assistantOverrides(db, hanging),
      );
      c = container;
      try {
        await enableApp(container, whatsapp, label: 'WhatsApp');
        hanging.hang = true;
        await assistantBootstrap(container);
        hanging.emit(ev());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await container.read(ingestionServiceProvider).ingest(const []);
        expect(
          await container.read(assistantRepositoryProvider).capturedCount(),
          1,
        );
      } finally {
        await assistantShutdown();
        await hanging.dispose();
      }
    });
  });
}

class _HangingConfigPlatform extends FakeAssistantPlatform {
  _HangingConfigPlatform()
    : super(listenerEnabled: true, listenerConnected: true);

  bool hang = false;

  @override
  Future<bool> setConfig(NativeAssistantConfig config) {
    // Never completes: simulates a stuck platform channel on cold start.
    if (hang) return Completer<bool>().future;
    return super.setConfig(config);
  }
}
