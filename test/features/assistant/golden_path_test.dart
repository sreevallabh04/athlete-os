// Golden path of the messaging assistant, end to end through the providers:
// captured WhatsApp notification → AI draft → user approves → exactly one
// hand-off to the platform → audit trail; the same event again is a no-op.
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:athlete_os/features/assistant/domain/hashing.dart';
import 'package:athlete_os/features/assistant/domain/safe_log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'assistant_test_utils.dart';

void main() {
  late AppDatabase db;
  late FakeAssistantPlatform platform;
  late ProviderContainer c;
  late List<String> logs;
  late void Function(String) originalSink;

  setUp(() {
    db = newTestDb();
    platform = FakeAssistantPlatform(
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
    await platform.dispose();
    await db.close();
  });

  test('WhatsApp: capture → draft → approve → one hand-off → audit; the '
      'same event again creates nothing', () async {
    final drafter = FakeDrafter();
    c = assistantContainer(db, platform, drafter: drafter);
    final repo = c.read(assistantRepositoryProvider);
    final ingestion = c.read(ingestionServiceProvider)..start();
    final replies = c.read(replyServiceProvider);

    await enableApp(c, whatsapp, allowAi: true, label: 'WhatsApp');
    await c.read(assistantControllerProvider).setAiConsent(true);

    // The event as the native listener produces it (with its dedupe hash).
    final postedAt = testNow.subtract(const Duration(minutes: 2)).toUtc();
    const text = 'Are we still on for dinner tonight?';
    final event = CapturedEvent(
      notificationKey: '0|com.whatsapp|1|null|10123',
      packageName: whatsapp,
      conversationKey: 'shortcut-mom',
      identityConfidence: 'high',
      title: 'Mom',
      sender: 'Mom',
      text: text,
      postedAt: postedAt,
      hasReplyAction: true,
      dedupeHash: dedupeHashFor(
        packageName: whatsapp,
        conversationKey: 'shortcut-mom',
        text: text,
        postedAt: postedAt,
      ),
    );

    // 1. Captured live from the notification listener.
    platform.emit(event);
    await Future<void>.delayed(Duration.zero);
    await ingestion.ingest(const []); // flush the serialised chain

    // 2. One draft, written by the (fake) AI drafter, waiting for the user.
    final drafts = await repo.allDrafts();
    expect(drafts, hasLength(1));
    final draft = drafts.single;
    expect(draft.status, DraftStatus.draft);
    expect(draft.draftText, 'Got it, thanks!');
    expect(draft.packageName, whatsapp);
    expect(drafter.requests, hasLength(1));
    expect(drafter.requests.single.messages.map((m) => m.text), [text]);
    // Draft mode: nothing has been sent on its own.
    expect(platform.sendCalls, isEmpty);

    // 3. The user taps Send (twice — the second tap must be a no-op).
    final first = await replies.approveAndSend(draft.id);
    final second = await replies.approveAndSend(draft.id);
    expect(first.status, DraftStatus.handedOff);
    expect(second.status, 'refused');

    // 4. Exactly one hand-off to the notification's reply action.
    expect(platform.sendCalls, hasLength(1));
    final call = platform.sendCalls.single;
    expect(call.key, event.notificationKey);
    expect(call.text, 'Got it, thanks!');
    expect(call.idempotencyKey, draft.idempotencyKey);

    final sent = (await repo.draft(draft.id))!;
    expect(sent.status, DraftStatus.handedOff);
    expect(sent.sentAt, isNotNull);

    // 5. Audit trail: one capture, one approve, one send — content-free.
    final audit = await repo.auditRows();
    int count(String action) => audit.where((a) => a.action == action).length;
    expect(count(AuditAction.capture), 1);
    expect(count(AuditAction.approve), 1);
    expect(count(AuditAction.send), 1);
    final sendRow = audit.singleWhere((a) => a.action == AuditAction.send);
    expect(sendRow.refId, draft.id);
    expect(sendRow.detail, contains('code=handed_off'));
    expect(sendRow.detail, contains('trigger=user_tap'));
    for (final a in audit) {
      expect('${a.detail} ${a.conversationKey}', isNot(contains('dinner')));
      expect('${a.detail} ${a.conversationKey}', isNot(contains('Mom')));
    }

    // 6. The same event again (re-delivered live and via the native queue).
    platform.queue.add(event);
    platform.emit(event);
    await Future<void>.delayed(Duration.zero);
    final again = await ingestion.drainAndIngest();
    await ingestion.ingest(const []);
    expect(again.duplicates, 1);
    expect(await repo.capturedCount(), 1);
    expect(await repo.allDrafts(), hasLength(1));
    expect(platform.sendCalls, hasLength(1));
    expect(drafter.requests, hasLength(1));

    // Logs never contain the message, the contact or the draft.
    for (final line in logs) {
      expect(line, isNot(contains('dinner')));
      expect(line, isNot(contains('Mom')));
      expect(line, isNot(contains('Got it')));
    }
  });
}
