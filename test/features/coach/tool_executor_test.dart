import 'dart:convert';

import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/coach/tools/tool_args_validator.dart';
import 'package:athlete_os/features/coach/tools/tool_executor.dart';
import 'package:athlete_os/features/coach/tools/tool_spec.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

void main() {
  test(
    'health tools require consent and are not audited until granted',
    () async {
      final db = newTestDb();
      addTearDown(db.close);
      final ex = executorFor(db);
      final out = await ex.execute(
        conversationId: 'c',
        toolCallId: 't1',
        name: 'get_nutrition_summary',
        args: const {},
      );
      expect(out.kind, ToolOutcomeKind.consentRequired);
      expect(out.consent, ToolConsent.health);
      expect(out.result['status'], 'consent_required');
      expect(await db.select(db.aiToolActions).get(), isEmpty);

      await grantHealthConsent(db);
      final ok = await ex.execute(
        conversationId: 'c',
        toolCallId: 't1',
        name: 'get_nutrition_summary',
        args: const {},
      );
      expect(ok.kind, ToolOutcomeKind.result);
      expect(ok.isError, isFalse);
      final audit = await db.select(db.aiToolActions).getSingle();
      expect(audit.status, 'ok');
      expect(audit.idempotencyKey, 'c:t1');
      expect(audit.isWrite, isFalse);
    },
  );

  test('journal tool needs journal consent, not health consent', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await grantHealthConsent(db);
    final ex = executorFor(db);
    final out = await ex.execute(
      conversationId: 'c',
      toolCallId: 'j',
      name: 'get_journal_summary',
      args: const {},
    );
    expect(out.kind, ToolOutcomeKind.consentRequired);
    expect(out.consent, ToolConsent.journal);
    await SettingsRepository(db).set(SettingKeys.aiJournalConsent, true);
    final ok = await ex.execute(
      conversationId: 'c',
      toolCallId: 'j',
      name: 'get_journal_summary',
      args: const {},
    );
    expect(ok.kind, ToolOutcomeKind.result);
  });

  test('write tools wait for confirmation, then run exactly once', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await grantHealthConsent(db);
    final ex = executorFor(db);
    final pending = await ex.execute(
      conversationId: 'c',
      toolCallId: 'w1',
      name: 'log_water',
      args: const {'amount_ml': 500},
    );
    expect(pending.kind, ToolOutcomeKind.pendingConfirmation);
    expect(await db.select(db.waterLogs).get(), isEmpty);
    var audit = await db.select(db.aiToolActions).getSingle();
    expect(audit.status, 'pending_confirmation');
    expect(audit.isWrite, isTrue);

    // Asking again without confirmation still does not write.
    await ex.execute(
      conversationId: 'c',
      toolCallId: 'w1',
      name: 'log_water',
      args: const {'amount_ml': 500},
    );
    expect(await db.select(db.waterLogs).get(), isEmpty);

    final done = await ex.execute(
      conversationId: 'c',
      toolCallId: 'w1',
      name: 'log_water',
      args: const {'amount_ml': 500},
      confirmed: true,
    );
    expect(done.kind, ToolOutcomeKind.result);
    expect(done.result['status'], 'logged');
    expect(done.replayed, isFalse);
    final rows = await db.select(db.waterLogs).get();
    expect(rows, hasLength(1));
    expect(rows.single.source, 'ai');
    audit = await db.select(db.aiToolActions).getSingle();
    expect(audit.status, 'confirmed');
    expect(audit.confirmedAt, isNotNull);

    // Retried round: same idempotency key replays the stored result.
    final replay = await ex.execute(
      conversationId: 'c',
      toolCallId: 'w1',
      name: 'log_water',
      args: const {'amount_ml': 500},
      confirmed: true,
    );
    expect(replay.replayed, isTrue);
    expect(replay.result['status'], 'logged');
    expect(await db.select(db.waterLogs).get(), hasLength(1));
    expect(await db.select(db.aiToolActions).get(), hasLength(1));
  });

  test('edited arguments are validated and recorded', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await grantHealthConsent(db);
    final ex = executorFor(db);
    await ex.execute(
      conversationId: 'c',
      toolCallId: 'w',
      name: 'log_water',
      args: const {'amount_ml': 500},
    );
    final out = await ex.execute(
      conversationId: 'c',
      toolCallId: 'w',
      name: 'log_water',
      args: const {'amount_ml': 500},
      confirmed: true,
      editedArgs: const {'amount_ml': 250},
    );
    expect(out.result['amount_ml'], 250);
    final audit = await db.select(db.aiToolActions).getSingle();
    expect(jsonDecode(audit.argsJson), {'amount_ml': 250});
    expect((await db.select(db.waterLogs).getSingle()).amountMl, 250);
  });

  test('rejection is audited and nothing is written', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await grantHealthConsent(db);
    final ex = executorFor(db);
    await ex.execute(
      conversationId: 'c',
      toolCallId: 'm',
      name: 'log_mood',
      args: const {'mood': 4},
    );
    final out = await ex.reject(
      conversationId: 'c',
      toolCallId: 'm',
      name: 'log_mood',
      args: const {'mood': 4},
    );
    expect(out.result['status'], 'rejected_by_user');
    expect(await db.select(db.moodEntries).get(), isEmpty);
    expect((await db.select(db.aiToolActions).getSingle()).status, 'rejected');
    // A later "confirmed" replay cannot resurrect the rejected write.
    final again = await ex.execute(
      conversationId: 'c',
      toolCallId: 'm',
      name: 'log_mood',
      args: const {'mood': 4},
      confirmed: true,
    );
    expect(again.replayed, isTrue);
    expect(await db.select(db.moodEntries).get(), isEmpty);
  });

  test('invalid args and unknown tools become is_error results', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await grantHealthConsent(db);
    final ex = executorFor(db);
    final bad = await ex.execute(
      conversationId: 'c',
      toolCallId: 'b',
      name: 'log_water',
      args: const {'amount_ml': 99999, 'extra': true},
      confirmed: true,
    );
    expect(bad.isError, isTrue);
    expect(bad.result['error'], 'invalid_arguments');
    expect(await db.select(db.waterLogs).get(), isEmpty);
    final block = bad.toResultBlock();
    expect(block['is_error'], true);
    expect(block['tool_call_id'], 'b');

    final unknown = await ex.execute(
      conversationId: 'c',
      toolCallId: 'u',
      name: 'drop_tables',
      args: const {},
    );
    expect(unknown.isError, isTrue);
    expect(unknown.result['error'], 'unknown_tool');
  });

  test(
    'handler errors are redacted before reaching the model or audit',
    () async {
      final db = newTestDb();
      addTearDown(db.close);
      final boom = ToolSpec(
        name: 'boom',
        description: 'fails',
        inputSchema: S.object({}),
        chipLabel: (a, n) => 'boom',
        handler: (ctx, args) async => throw StateError(
          'upstream failed api_key=sk-ant-abcdefghijklmnop12345',
        ),
      );
      final ex = executorFor(db, tools: [boom]);
      final out = await ex.execute(
        conversationId: 'c',
        toolCallId: 'x',
        name: 'boom',
        args: const {},
      );
      expect(out.isError, isTrue);
      final encoded = jsonEncode(out.result);
      expect(encoded, isNot(contains('sk-ant-abcdefghijklmnop12345')));
      expect(encoded, contains('REDACTED'));
      final audit = await db.select(db.aiToolActions).getSingle();
      expect(audit.status, 'error');
      expect(audit.resultSummary, isNot(contains('sk-ant-')));
    },
  );
}
