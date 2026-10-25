import 'dart:convert';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

void main() {
  late AppDatabase db;
  late FakeAiBackend backend;
  late ProviderContainer container;

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [
        ...testOverrides(db, now: testNow),
        aiBackendClientProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  CoachController controller() =>
      container.read(coachControllerProvider.notifier);
  CoachState state() => container.read(coachControllerProvider);

  List<Map<String, Object?>> toolResults(AiChatRequest req) => [
    for (final m in req.messages)
      for (final b in (m['content'] as List).cast<Map<String, Object?>>())
        if (b['type'] == 'tool_result') b,
  ];

  setUp(() {
    db = newTestDb();
    addTearDown(db.close);
  });

  test('tool call → local result → final answer', () async {
    await db
        .into(db.competitions)
        .insert(
          CompetitionsCompanion.insert(
            id: 'c',
            name: 'Nationals',
            eventDate: '2026-11-04',
            tzName: 'UTC',
          ),
        );
    backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'tc1', 'get_competition_countdown'),
      (r) => FakeAiBackend.text(r, 'You have **10 days** to go.'),
    ]);
    container = makeContainer();
    await controller().send('Days until my competition?');

    expect(backend.requests, hasLength(2));
    final first = backend.requests.first;
    expect(first.tools.map((t) => t['name']), contains('log_food'));
    expect(first.messages.last['role'], 'user');
    expect(first.system, contains('2026-10-25'));
    final results = toolResults(backend.requests[1]);
    expect(results.single['tool_call_id'], 'tc1');
    final content = jsonDecode(results.single['content'] as String) as Map;
    expect((content['competitions'] as List).first['name'], 'Nationals');
    // Different model calls use different request ids.
    expect(backend.requests[0].requestId, isNot(backend.requests[1].requestId));

    final s = state();
    expect(s.busy, isFalse);
    expect(s.error, isNull);
    expect(
      s.entries.whereType<UserTextEntry>().single.text,
      'Days until my competition?',
    );
    final chip = s.entries.whereType<ToolChipEntry>().single;
    expect(chip.status, ToolChipStatus.ok);
    expect(chip.label, 'Read competitions');
    final answer = s.entries.whereType<AssistantTextEntry>().last;
    expect(answer.text, contains('10 days'));
    expect(answer.sources, contains('Competition planner'));

    final msgs = await db.select(db.aiMessages).get();
    expect(msgs.map((m) => m.role).toList()..sort(), [
      'assistant',
      'assistant',
      'tool',
      'user',
    ]);
    expect(
      msgs.where((m) => m.role == 'assistant').first.provider,
      'anthropic',
    );
    expect((await db.select(db.aiToolActions).getSingle()).status, 'ok');
  });

  test(
    'write tool pauses for confirmation; approve executes then continues',
    () async {
      await grantHealthConsent(db);
      backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'w1', 'log_water', {'amount_ml': 500}),
        (r) => FakeAiBackend.text(r, 'Logged 500 ml.'),
      ]);
      container = makeContainer();
      await controller().send('I drank 500 ml');

      expect(backend.requests, hasLength(1));
      final pending = state().pending;
      expect(pending, isNotNull);
      expect(pending!.isConsent, isFalse);
      expect(pending.title, 'Log water');
      expect(pending.summary.first, contains('500 ml'));
      expect(await db.select(db.waterLogs).get(), isEmpty);
      expect(
        state().entries.whereType<ToolChipEntry>().single.status,
        ToolChipStatus.pending,
      );

      await controller().approve();
      expect(await db.select(db.waterLogs).get(), hasLength(1));
      expect(backend.requests, hasLength(2));
      final result = toolResults(backend.requests[1]).single;
      expect(result['content'], contains('"logged"'));
      expect(state().pending, isNull);
      expect(
        state().entries.whereType<AssistantTextEntry>().last.text,
        'Logged 500 ml.',
      );
    },
  );

  test(
    'rejected write is reported to the model and nothing is written',
    () async {
      await grantHealthConsent(db);
      backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'm1', 'log_mood', {'mood': 2}),
        (r) => FakeAiBackend.text(r, 'Okay, not logged.'),
      ]);
      container = makeContainer();
      await controller().send('log my mood as 2');
      expect(state().pending, isNotNull);
      await controller().reject();

      expect(await db.select(db.moodEntries).get(), isEmpty);
      expect(
        (await db.select(db.aiToolActions).getSingle()).status,
        'rejected',
      );
      final result = toolResults(backend.requests[1]).single;
      expect(result['content'], contains('rejected_by_user'));
      expect(
        state().entries.whereType<ToolChipEntry>().single.status,
        ToolChipStatus.rejected,
      );
    },
  );

  test('consent card: allowing consent re-runs the tool', () async {
    backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'n1', 'get_nutrition_summary'),
      (r) => FakeAiBackend.text(r, 'Nothing logged yet today.'),
    ]);
    container = makeContainer();
    await controller().send('How much protein do I have left today?');
    final p = state().pending!;
    expect(p.isConsent, isTrue);
    expect(backend.requests, hasLength(1));

    await controller().approve();
    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.aiHealthConsent),
      isTrue,
    );
    final result = toolResults(backend.requests[1]).single;
    expect(result['content'], contains('"remaining"'));
  });

  test('declined consent sends consent_declined without data', () async {
    await addFood(db, id: 'f', date: testToday, kcal: 999, name: 'SecretMeal');
    backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'n1', 'get_nutrition_summary'),
      (r) => FakeAiBackend.text(r, 'Okay.'),
    ]);
    container = makeContainer();
    await controller().send('What did I eat?');
    await controller().reject();
    final result = toolResults(backend.requests[1]).single;
    expect(result['content'], contains('consent_declined'));
    expect(
      jsonEncode(backend.requests[1].toJson()),
      isNot(contains('SecretMeal')),
    );
  });

  test('stops after the maximum number of tool rounds', () async {
    var n = 0;
    backend = FakeAiBackend([
      (r) =>
          FakeAiBackend.toolCall(r, 'loop${n++}', 'get_competition_countdown'),
    ]);
    container = makeContainer();
    await controller().send('loop forever');
    expect(backend.requests, hasLength(maxToolRounds + 1));
    expect(state().busy, isFalse);
    expect(state().notice, contains('Stopped after $maxToolRounds'));
    // The extra call was closed with a result so history stays valid.
    final last = (await db.select(db.aiMessages).get()).where(
      (m) => m.role == 'tool',
    );
    expect(last, hasLength(maxToolRounds + 1));
  });

  test('retry after a backend error reuses the same request id', () async {
    var fail = true;
    backend = FakeAiBackend([
      (r) {
        if (fail) {
          fail = false;
          throw const AiBackendException('upstream_error', 'Provider hiccup.');
        }
        return FakeAiBackend.text(r, 'Recovered.');
      },
    ]);
    container = makeContainer();
    await controller().send('hello');
    expect(state().error?.code, 'upstream_error');
    expect(state().canRetry, isTrue);
    await controller().retry();
    expect(backend.requests, hasLength(2));
    expect(backend.requests[0].requestId, backend.requests[1].requestId);
    expect(state().error, isNull);
    expect(
      state().entries.whereType<AssistantTextEntry>().single.text,
      'Recovered.',
    );
  });

  test('does not call the model when the backend is not ready', () async {
    db = newTestDb();
    addTearDown(db.close);
    final c = ProviderContainer(
      overrides: [
        ...testOverrides(db, now: testNow),
        aiBackendClientProvider.overrideWithValue(
          const UnconfiguredAiBackend(),
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(coachControllerProvider.notifier).send('hi');
    expect(c.read(coachControllerProvider).error?.code, 'awaiting_credentials');
    expect(await db.select(db.aiMessages).get(), isEmpty);
  });

  test('toWireMessages maps tool rows to user turns and merges roles', () {
    AiMessage msg(String role, List<Map<String, Object?>> blocks, int i) =>
        AiMessage(
          id: 'm$i',
          conversationId: 'c',
          role: role,
          contentJson: jsonEncode(blocks),
          createdAt: DateTime.utc(2026, 1, 1, 0, 0, i),
        );
    final rows = [
      msg('user', [
        {'type': 'text', 'text': 'hi'},
      ], 0),
      msg('assistant', [
        {
          'type': 'opaque',
          'provider': 'anthropic',
          'data': {'type': 'thinking'},
        },
        {'type': 'tool_call', 'id': 't', 'name': 'x', 'arguments': {}},
      ], 1),
      msg('tool', [
        {
          'type': 'tool_result',
          'tool_call_id': 't',
          'name': 'x',
          'content': '{}',
          'is_error': false,
        },
      ], 2),
      msg('user', [
        {'type': 'text', 'text': 'again'},
      ], 3),
    ];
    final wire = toWireMessages(rows);
    expect(wire.map((m) => m['role']), ['user', 'assistant', 'user']);
    final merged = (wire.last['content'] as List).cast<Map>();
    expect(merged.first['type'], 'tool_result');
    expect(merged.last['text'], 'again');
    expect((wire[1]['content'] as List).first['type'], 'opaque');

    // Trimming never starts on an orphaned tool result.
    final trimmed = toWireMessages(rows, maxMessages: 2);
    expect(trimmed.first['role'], 'user');
    expect(
      (trimmed.first['content'] as List).any(
        (b) => (b as Map)['type'] == 'tool_result',
      ),
      isFalse,
    );
  });
}
