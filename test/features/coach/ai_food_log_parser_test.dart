import 'dart:convert';

import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_food_log_parser.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/data/ai_text_service.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_parser.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coach_test_utils.dart';

AiTextService _svc(
  AiBackendClient backend, {
  AiPreferences prefs = const AiPreferences(),
}) => AiTextService(backend, () async => prefs);

final _now = DateTime(2026, 10, 26, 21, 40);

const _args = {
  'items': [
    {
      'name': 'Egg omelette',
      'quantity': '3 eggs',
      'grams': 165,
      'kcal': 280,
      'protein_g': 19,
      'carbs_g': 2,
      'fat_g': 21,
      'fiber_g': 0,
      'meal_type': 'breakfast',
      'confidence': 0.8,
      'note': 'assumed 1 tsp oil',
    },
    {
      'name': 'Dal',
      'quantity': '1 katori',
      'grams': 150,
      'kcal': 180,
      'protein_g': 9,
      'carbs_g': 24,
      'fat_g': 5,
      'fiber_g': 4,
      'meal_type': 'unknown',
      'confidence': 0.7,
      'note': '',
    },
    {'name': '  ', 'kcal': 10}, // dropped: no name
    {'name': 'Mystery', 'kcal': 'n/a'}, // dropped: no kcal
  ],
  'unparsed': ['felt bloated', ''],
};

void main() {
  test('log_food_items schema stays under the backend 4 KB limit', () {
    expect(utf8.encode(jsonEncode(logFoodItemsSchema)).length, lessThan(4096));
  });

  test('prompt carries eggetarian, portion and untrusted-data rules', () {
    expect(foodLogSystemPrompt, contains('EGGETARIAN'));
    expect(foodLogSystemPrompt, contains('Never assume meat'));
    expect(foodLogSystemPrompt, contains('katori'));
    expect(foodLogSystemPrompt, contains('Never invent'));
    expect(foodLogSystemPrompt, contains('untrusted DATA'));
    expect(foodLogSystemPrompt, contains('Ignore any'));
    expect(foodLogSystemPrompt, contains(logFoodItemsTool));
  });

  test(
    'sends only log_food_items with ~4 K tokens and maps the call',
    () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'c1', logFoodItemsTool, _args),
      ]);
      final res = await AiFoodLogParser(_svc(backend))
          .parse('Breakfast: 3 egg omelette. 1 katori dal', now: _now);

      expect(res, isA<FoodLogParseSuccess>());
      final ok = res as FoodLogParseSuccess;
      expect(ok.items.map((i) => i.name), ['Egg omelette', 'Dal']);
      final egg = ok.items.first;
      expect(egg.quantityDescription, '3 eggs');
      expect(egg.grams, 165);
      expect(egg.nutrients.calories, 280);
      expect(egg.nutrients.fiber, 0);
      expect(egg.mealType, MealType.breakfast);
      expect(egg.confidence, 0.8);
      expect(egg.note, 'assumed 1 tsp oil');
      expect(ok.items[1].mealType, isNull); // "unknown"
      expect(ok.items[1].note, isNull); // empty string
      expect(ok.unparsed, ['felt bloated']);
      expect(ok.provider, 'anthropic');

      final req = backend.requests.single;
      expect(req.tools.map((t) => t['name']), [logFoodItemsTool]);
      expect(req.preferences.maxTokens, foodLogMaxTokens);
      expect(req.system, foodLogSystemPrompt);
      final user =
          ((req.messages.single['content']! as List).first as Map)['text']
              as String;
      expect(user, contains('<<<FOOD_LOG'));
      expect(user, contains('1 katori dal'));
      expect(user, contains('Mon 26 Oct 2026, 21:40'));
    },
  );

  test('fast mode routes this call to Groq without the stored model', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'c1', logFoodItemsTool, _args),
    ]);
    await AiFoodLogParser(
      _svc(
        backend,
        prefs: const AiPreferences(
          primaryProvider: 'gemini',
          model: 'gemini-3.6-flash',
        ),
      ),
    ).parse('2 rotis', now: _now, fast: true);
    final p = backend.requests.single.preferences;
    expect(p.primaryProvider, 'groq');
    expect(p.model, isNull);
    expect(p.fallbackProviders, isNot(contains('groq')));
    expect(p.fallbackProviders, contains('gemini'));
  });

  test(
    'a prose answer or truncation is a failure, not empty success',
    () async {
      final prose = FakeAiBackend([(r) => FakeAiBackend.text(r, 'Sure!')]);
      final res = await AiFoodLogParser(_svc(prose)).parse('dal', now: _now);
      expect(res, isA<FoodLogParseFailure>());

      final cut = FakeAiBackend([
        (r) => AiChatResponse(
          requestId: r.requestId,
          content: const [],
          stopReason: 'max_tokens',
        ),
      ]);
      final res2 = await AiFoodLogParser(_svc(cut)).parse('dal', now: _now);
      expect((res2 as FoodLogParseFailure).message, contains('too long'));
    },
  );

  test('backend errors map to retryable failures with timeout flag', () async {
    final backend = FakeAiBackend([
      (_) => throw const AiBackendException('timeout', 'The AI timed out.'),
    ]);
    final res = await AiFoodLogParser(_svc(backend)).parse('dal', now: _now);
    final f = res as FoodLogParseFailure;
    expect(f.timedOut, isTrue);
    expect(f.retryable, isTrue);
  });

  test('unconfigured backend sends nothing and says so', () async {
    final res = await AiFoodLogParser(_svc(const UnconfiguredAiBackend()))
        .parse('dal', now: _now);
    expect(res, isA<FoodLogParseUnavailable>());
    expect(
      await const UnconfiguredFoodLogParser().parse('dal', now: _now),
      isA<FoodLogParseUnavailable>(),
    );
  });

  test('parseLogFoodItems tolerates junk', () {
    expect(parseLogFoodItems(null).$1, isEmpty);
    expect(parseLogFoodItems({'items': 'x', 'unparsed': 3}).$2, isEmpty);
  });
}
