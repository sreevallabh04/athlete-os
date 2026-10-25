import 'dart:convert';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/agent/system_prompt.dart';
import 'package:athlete_os/features/coach/agent/tool_router.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coach_test_utils.dart';

AiMessage _row(int i, String role, List<Map<String, Object?>> blocks) =>
    AiMessage(
      id: 'm$i',
      conversationId: 'c',
      role: role,
      contentJson: jsonEncode(blocks),
      createdAt: DateTime.utc(2026, 10, 26, 8, i),
    );

/// A realistic 5-turn history: each turn = question, tool call, tool
/// result (~1.6 KB like a single-day nutrition summary), answer.
List<AiMessage> _history({int turns = 5}) {
  final rows = <AiMessage>[];
  var i = 0;
  final bigResult = jsonEncode({
    'date': '2026-10-26',
    'totals': {'calories_kcal': 1210, 'protein_g': 79},
    'entries': [
      for (var k = 0; k < 12; k++)
        {
          'id': 'food-$k-abcdef',
          'name': 'Food item number $k with a long name',
          'meal': 'lunch',
          'calories_kcal': 180.5,
          'protein_g': 12.5,
          'carbs_g': 20.1,
          'fat_g': 6.2,
          'verification': 'user_entered',
        },
    ],
    'provenance': {
      'sources': ['Manual log'],
      'as_of': '2026-10-26T08:00:00Z',
    },
  });
  for (var t = 0; t < turns; t++) {
    rows
      ..add(
        _row(i++, 'user', [
          {'type': 'text', 'text': 'How much protein do I have left? ($t)'},
        ]),
      )
      ..add(
        _row(i++, 'assistant', [
          {
            'type': 'tool_call',
            'id': 'tc$t',
            'name': 'get_nutrition_summary',
            'arguments': {'date': '2026-10-26'},
          },
        ]),
      )
      ..add(
        _row(i++, 'tool', [
          {
            'type': 'tool_result',
            'tool_call_id': 'tc$t',
            'name': 'get_nutrition_summary',
            'content': bigResult,
            'is_error': false,
          },
        ]),
      )
      ..add(
        _row(i++, 'assistant', [
          {
            'type': 'text',
            'text':
                'You have **91 g** of protein left. A 250 g chicken breast '
                'covers most of it; a whey shake covers the rest.',
          },
        ]),
      );
  }
  return rows;
}

void main() {
  test('routes by intent, always with the core set, capped at 8', () {
    final protein = routeTools('How much protein do I have left today?');
    expect(protein.names.take(2), coreTools);
    expect(protein.names, contains('get_nutrition_summary'));
    expect(protein.names, isNot(contains('get_calendar_events')));
    expect(protein.categories.first, 'nutrition');

    final water = routeTools('I drank 500 ml of water');
    expect(water.names, containsAll(['log_water', 'get_water_summary']));

    final bench = routeTools('How is my bench press progressing?');
    expect(bench.names, contains('get_strength_progress'));

    final slot = routeTools('Plan a 45-min workout slot today');
    expect(
      slot.names,
      containsAll(['suggest_schedule', 'get_workout_history']),
    );

    final comp = routeTools('Days until my competition?');
    expect(comp.names, contains('get_competition_countdown'));

    final mix = routeTools(
      'Plan my meals, water, steps, workouts, calendar, habits and mood',
    );
    expect(mix.names.length, lessThanOrEqualTo(maxRoutedTools));
    // Every matched category still gets its primary tool (round-robin).
    expect(
      mix.names,
      containsAll([
        'get_nutrition_summary',
        'get_water_summary',
        'get_steps_summary',
      ]),
    );
    for (final r in [protein, water, bench, slot, comp, mix]) {
      expect(r.names.length, lessThanOrEqualTo(maxRoutedTools));
      expect(r.names.toSet().length, r.names.length);
      expect(r.specs.length, r.names.length, reason: 'all names registered');
    }
  });

  test('follow-ups reuse recent tools; no match falls back to general', () {
    final f = routeTools(
      'and yesterday?',
      recentTools: ['get_nutrition_summary'],
    );
    expect(f.reason, 'follow_up');
    expect(f.names, contains('get_nutrition_summary'));

    final g = routeTools('hello there');
    expect(g.reason, 'general');
    expect(g.names, containsAll(coreTools));
    expect(g.names.length, lessThanOrEqualTo(maxRoutedTools));

    expect(fullToolRoute().names.length, coachTools.length);
  });

  test('typical request ≤ 6K tokens and fits Groq; logs before/after', () {
    final system = buildSystemPrompt(
      SystemPromptInputs(
        now: testNow,
        tzName: 'IST',
        persona: defaultAiPersona,
      ),
    );
    final rows = [
      ..._history(),
      _row(99, 'user', [
        {'type': 'text', 'text': 'How much protein do I have left today?'},
      ]),
    ];
    final before = RequestSize.of(
      system: system,
      tools: [for (final t in coachTools) t.toWire()],
      messages: toWireMessages(rows),
    );
    final route = routeTools('How much protein do I have left today?');
    final after = RequestSize.of(
      system: system,
      tools: [for (final t in route.specs) t.toWire()],
      messages: toWireMessages(
        rows,
        maxChars: historyCharBudget,
        compactOldToolResults: true,
      ),
    );
    final cold = RequestSize.of(
      system: system,
      tools: [for (final t in route.specs) t.toWire()],
      messages: toWireMessages(rows.sublist(rows.length - 1)),
    );
    // ignore: avoid_print
    print('before (all tools, full history): $before');
    // ignore: avoid_print
    print('after  (routed, compacted):       $after');
    // ignore: avoid_print
    print('first message of a session:      $cold');
    expect(after.total, lessThanOrEqualTo(6000));
    expect(cold.total, lessThanOrEqualTo(3000));
    expect(after.toolTokens, lessThan(before.toolTokens ~/ 2));
    expect(after.total, lessThan(before.total));
  });

  test('history compaction trims only earlier turns and keeps pairs', () {
    final rows = [
      ..._history(turns: 2),
      _row(98, 'user', [
        {'type': 'text', 'text': 'and now?'},
      ]),
      _row(99, 'assistant', [
        {
          'type': 'tool_call',
          'id': 'now',
          'name': 'get_nutrition_summary',
          'arguments': <String, Object?>{},
        },
      ]),
      _row(100, 'tool', [
        {
          'type': 'tool_result',
          'tool_call_id': 'now',
          'name': 'get_nutrition_summary',
          'content': 'x' * 900,
          'is_error': false,
        },
      ]),
      _row(101, localRole, [
        {'type': 'text', 'text': 'LOCAL BRIEFING NEVER SENT'},
      ]),
    ];
    final wire = toWireMessages(rows, compactOldToolResults: true);
    final results = [
      for (final m in wire)
        for (final b in (m['content'] as List).cast<Map<String, Object?>>())
          if (b['type'] == 'tool_result') b,
    ];
    expect(results.length, 3);
    expect(
      results.take(2).every((r) => r['content'] == trimmedToolResult),
      isTrue,
    );
    expect(results.last['content'], 'x' * 900);
    expect(jsonEncode(wire), isNot(contains('LOCAL BRIEFING')));
  });

  test('recentToolNames lists newest first without duplicates', () {
    final names = recentToolNames(_history(turns: 3));
    expect(names, ['get_nutrition_summary']);
  });
}
