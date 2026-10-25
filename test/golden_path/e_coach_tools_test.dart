import 'dart:convert';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/tools/tool_executor.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/coach/coach_test_utils.dart';
import '../helpers/test_app.dart';
import 'golden_helpers.dart';

void main() {
  late AppDatabase db;
  late FakeAiBackend backend;
  late ProviderContainer container;

  CoachController coach() => container.read(coachControllerProvider.notifier);
  CoachState state() => container.read(coachControllerProvider);

  List<Map<String, Object?>> toolResults(AiChatRequest req) => [
    for (final m in req.messages)
      if (m['content'] is List)
        for (final b in (m['content'] as List).cast<Map<String, Object?>>())
          if (b['type'] == 'tool_result') b,
  ];

  Map<String, Object?> lastResultFor(String toolCallId) {
    final all = [for (final r in backend.requests) ...toolResults(r)];
    final block = all.lastWhere((b) => b['tool_call_id'] == toolCallId);
    return (jsonDecode(block['content'] as String) as Map)
        .cast<String, Object?>();
  }

  Future<List<WaterLog>> waterRows() => db.select(db.waterLogs).get();

  setUp(() async {
    db = newTestDb();
    addTearDown(db.close);
    backend = FakeAiBackend([]);
    container = goldenContainer(
      db,
      extra: [aiBackendClientProvider.overrideWithValue(backend)],
    );
    await grantHealthConsent(db);
    // Two real food logs today: 62 g protein of the 150 g default target.
    final log = FoodLogRepository(db, FixedClock(goldenNow));
    await log.quickAdd(
      name: 'Egg white omelette',
      nutrients: const Nutrients(calories: 210, protein: 26),
      mealType: MealType.breakfast,
      localDate: goldenToday,
    );
    await log.quickAdd(
      name: 'Whey shake',
      nutrients: const Nutrients(calories: 160, protein: 36),
      mealType: MealType.snack,
      localDate: goldenToday,
    );
  });

  test('"how much protein left" → nutrition read tool returns target − '
      'logged, matching Today', () async {
    backend.responders.addAll([
      (r) => FakeAiBackend.toolCall(r, 'p1', 'get_nutrition_summary'),
      (r) => FakeAiBackend.text(r, 'You have 88 g of protein left today.'),
    ]);
    await coach().send('How much protein do I have left today?');

    expect(backend.requests, hasLength(2));
    // The router offered the nutrition read tool for this question.
    expect(
      backend.requests.first.tools.map((t) => t['name']),
      contains('get_nutrition_summary'),
    );
    final result = lastResultFor('p1');
    final targets = (result['targets']! as Map).cast<String, Object?>();
    final totals = (result['totals']! as Map).cast<String, Object?>();
    final remaining = (result['remaining']! as Map).cast<String, Object?>();
    expect(result['date'], goldenToday);
    expect(targets['protein_g'], 150);
    expect(totals['protein_g'], 62);
    expect(remaining['protein_g'], 88); // 150 − (26 + 36)
    expect(remaining['calories_kcal'], 2000 - 370);

    // Deterministic: the same number Today derives from the same data.
    final snap = await readFirst(
      container,
      todaySnapshotProvider.future,
      todaySnapshotProvider,
    );
    expect(
      snap.profile.proteinTargetG - snap.nutrition.proteinG,
      remaining['protein_g'],
    );

    final audit = await db.select(db.aiToolActions).getSingle();
    expect(audit.toolName, 'get_nutrition_summary');
    expect(audit.status, 'ok');
    expect(state().pending, isNull);
    expect(
      state().entries.whereType<AssistantTextEntry>().last.text,
      'You have 88 g of protein left today.',
    );
  });

  test('write tool waits for approval, runs exactly once, and a replay with '
      'the same idempotency key does not double-write', () async {
    backend.responders.addAll([
      (r) => FakeAiBackend.toolCall(r, 'w1', 'log_water', {'amount_ml': 500}),
      (r) => FakeAiBackend.text(r, 'Logged 500 ml.'),
    ]);
    await coach().send('I just drank 500 ml of water');

    // Pending approval: nothing written, model not called again.
    final pending = state().pending;
    expect(pending, isNotNull);
    expect(pending!.isConsent, isFalse);
    expect(pending.toolName, 'log_water');
    expect(pending.toolCallId, 'w1');
    expect(backend.requests, hasLength(1));
    expect(await waterRows(), isEmpty);
    final queued = await db.select(db.aiToolActions).getSingle();
    expect(queued.status, 'pending_confirmation');
    final conversationId = state().conversationId!;
    expect(queued.idempotencyKey, ToolExecutor.keyFor(conversationId, 'w1'));

    // Approve (a double tap must not run it twice).
    await Future.wait([coach().approve(), coach().approve()]);
    var rows = await waterRows();
    expect(rows, hasLength(1));
    expect(rows.single.amountMl, 500);
    expect(rows.single.source, 'ai');
    expect(rows.single.localDate, goldenToday);
    expect(state().pending, isNull);
    expect(backend.requests, hasLength(2));
    expect(lastResultFor('w1')['status'], 'logged');
    expect(lastResultFor('w1')['today_total_ml'], 500);
    final confirmed = await db.select(db.aiToolActions).getSingle();
    expect(confirmed.status, 'confirmed');

    // Replay 1: executor called again with the same key (retried round).
    final replay = await container
        .read(toolExecutorProvider)
        .execute(
          conversationId: conversationId,
          toolCallId: 'w1',
          name: 'log_water',
          args: const {'amount_ml': 500},
          confirmed: true,
        );
    expect(replay.replayed, isTrue);
    expect(replay.result['status'], 'logged');
    expect(await waterRows(), hasLength(1));

    // A later turn that re-uses the provider's tool-call id is a NEW request
    // (ids are made unique per conversation), so it must ask again rather
    // than silently replaying — and still writes nothing until approved.
    backend.responders
      ..clear()
      ..addAll([
        (r) => FakeAiBackend.toolCall(r, 'w1', 'log_water', {'amount_ml': 500}),
        (r) => FakeAiBackend.text(r, 'Okay, not logged.'),
      ]);
    await coach().send('Log another 500 ml');
    final second = state().pending;
    expect(second, isNotNull);
    expect(second!.toolCallId, isNot('w1'));
    expect(await waterRows(), hasLength(1));
    await coach().reject();
    rows = await waterRows();
    expect(rows, hasLength(1), reason: 'rejected write is never executed');
    final audits = {
      for (final a in await db.select(db.aiToolActions).get())
        a.idempotencyKey: a.status,
    };
    expect(audits, {
      ToolExecutor.keyFor(conversationId, 'w1'): 'confirmed',
      ToolExecutor.keyFor(conversationId, second.toolCallId): 'rejected',
    });

    final snap = await readFirst(
      container,
      todaySnapshotProvider.future,
      todaySnapshotProvider,
    );
    expect(snap.waterMl, 500);
  });
}
