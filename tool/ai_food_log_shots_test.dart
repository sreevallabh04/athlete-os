// Visual QA for "Tell JARVIS what you ate" (AI bulk food logging): input,
// analysing and review (seeded with a realistic Indian day), dark + light.
//
//   flutter test tool/ai_food_log_shots_test.dart
//
// PNGs land in build/shots/ai-log/. The parser is a deterministic fake.
import 'dart:async';

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/features/nutrition/application/ai_food_log.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_parser.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/presentation/ai_food_log_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart';

final _now = DateTime(2026, 10, 25, 21, 40);

class _FakeParser implements FoodLogParser {
  _FakeParser({this.hang = false});
  final bool hang;

  @override
  bool get isConfigured => true;

  @override
  bool get supportsFastMode => true;

  @override
  Future<FoodLogParseResult> parse(
    String text, {
    required DateTime now,
    bool fast = false,
  }) {
    if (hang) return Completer<FoodLogParseResult>().future;
    return Future.value(_sampleParse);
  }
}

class _FakeDictation implements FoodDictation {
  @override
  Future<String?> start({
    required void Function(String words, bool isFinal) onWords,
    void Function(double level)? onLevel,
  }) async => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

ParsedFoodItem _p(
  String name,
  String qty,
  double g,
  double kcal,
  double p,
  double c,
  double f,
  double fiber,
  MealType m, {
  double conf = 0.85,
  String? note,
}) => ParsedFoodItem(
  name: name,
  quantityDescription: qty,
  grams: g,
  nutrients: Nutrients(
    calories: kcal,
    protein: p,
    carbs: c,
    fat: f,
    fiber: fiber,
  ),
  mealType: m,
  confidence: conf,
  note: note,
);

final _sampleParse = FoodLogParseSuccess([
  _p(
    'Egg omelette',
    '3 eggs',
    165,
    290,
    19,
    2,
    23,
    0,
    MealType.breakfast,
    note: 'assumed 1 tsp oil',
  ),
  _p('Roti', '2 rotis', 80, 240, 8, 44, 4, 5, MealType.breakfast),
  _p(
    'Black coffee',
    '1 cup',
    240,
    5,
    0.3,
    0,
    0,
    0,
    MealType.breakfast,
    conf: 0.95,
  ),
  _p(
    'Dal tadka',
    '1 katori',
    150,
    180,
    9,
    24,
    5,
    5,
    MealType.lunch,
    note: 'assumed 1 tsp ghee in the tadka',
  ),
  _p('Steamed rice', '1 cup', 150, 195, 4, 43, 0.5, 0.6, MealType.lunch),
  _p(
    'Paneer bhurji',
    '100 g paneer',
    150,
    360,
    20,
    8,
    28,
    1.5,
    MealType.lunch,
    conf: 0.7,
    note: 'assumed 2 tsp oil, onion and tomato',
  ),
  _p(
    'Salad',
    '1 plate',
    100,
    30,
    1,
    6,
    0.2,
    2,
    MealType.lunch,
    conf: 0.45,
    note: 'assumed cucumber, tomato, onion',
  ),
  _p('Whey protein', '1 scoop', 30, 120, 24, 3, 1.5, 0, MealType.snack),
  _p('Banana', '1 medium', 118, 105, 1.3, 27, 0.4, 3.1, MealType.snack),
  _p(
    'Besan chilla',
    '2 chillas',
    160,
    340,
    16,
    36,
    14,
    6,
    MealType.dinner,
    conf: 0.75,
    note: 'assumed 1 tsp oil each',
  ),
  _p('Curd', '1 katori', 150, 92, 5, 7, 5, 0, MealType.dinner),
], provider: 'gemini');

/// Morning chai already logged (feeds the before → after bars).
Future<void> _seed(WidgetTester t) async {
  final db = ProviderScope.containerOf(
    t.element(find.byType(AthleteOsApp)),
    listen: false,
  ).read(databaseProvider);
  var done = false;
  unawaited(
    FoodLogRepository(db, FixedClock(_now))
        .quickAdd(
          name: 'Masala chai',
          nutrients: const Nutrients(
            calories: 140,
            protein: 4,
            carbs: 18,
            fat: 6,
          ),
          mealType: MealType.breakfast,
          localDate: LocalDates.key(_now),
        )
        .then((_) => done = true),
  );
  for (var i = 0; !done && i < 2000; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
  }
}

Future<void> _frames(WidgetTester t, int ms) async {
  for (var i = 0; i < (ms / 50).ceil(); i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

String get _route => Uri(
  path: AppPaths.aiFoodLog,
  queryParameters: {'q': sampleDayLog},
).toString();

void main() {
  testWidgets(
    'ai-log input',
    (t) => shotRoute(
      t,
      _route,
      'ai-log/input',
      now: _now,
      scrolls: 1,
      overrides: [
        foodLogParserProvider.overrideWithValue(_FakeParser()),
        foodDictationProvider.overrideWithValue(_FakeDictation()),
      ],
    ),
  );
  testWidgets(
    'ai-log input empty light',
    (t) => shotRoute(
      t,
      AppPaths.aiFoodLog,
      'ai-log/input_empty_light',
      now: _now,
      light: true,
      overrides: [
        foodLogParserProvider.overrideWithValue(_FakeParser()),
        foodDictationProvider.overrideWithValue(_FakeDictation()),
      ],
    ),
  );
  testWidgets(
    'ai-log analysing',
    (t) => shotRoute(
      t,
      _route,
      'ai-log/analysing',
      now: _now,
      overrides: [
        foodLogParserProvider.overrideWithValue(_FakeParser(hang: true)),
      ],
      prepare: (t) async {
        await _frames(t, 600);
        await t.tap(find.byKey(const Key('ai-log-analyse')));
        await _frames(t, 4200);
      },
    ),
  );
  for (final light in [false, true]) {
    testWidgets(
      'ai-log review${light ? ' light' : ''}',
      (t) => shotRoute(
        t,
        _route,
        'ai-log/review${light ? '_light' : ''}',
        now: _now,
        light: light,
        scrolls: light ? 1 : 4,
        overrides: [foodLogParserProvider.overrideWithValue(_FakeParser())],
        prepare: (t) async {
          await _seed(t);
          await _frames(t, 600);
          await t.tap(find.byKey(const Key('ai-log-analyse')));
          await _frames(t, 400);
        },
      ),
    );
  }
  testWidgets(
    'ai-log unconfigured',
    (t) => shotRoute(t, _route, 'ai-log/unconfigured', now: _now),
  );
  testWidgets(
    'ai-log nutrition entry',
    (t) => shotRoute(
      t,
      AppPaths.nutrition,
      'ai-log/nutrition_tab',
      scrolls: 1,
      now: _now,
    ),
  );
}
