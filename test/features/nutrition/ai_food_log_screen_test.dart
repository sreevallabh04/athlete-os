import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/ai_food_log.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/data/indian_food_db.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_parser.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/presentation/ai_food_log_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/widgets/ai_log_widgets.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'nutrition_widgets_test.dart' show settleAndDispose, useTallView;

final _now = DateTime(2026, 10, 25, 21, 40);
const _today = '2026-10-25';

/// Deterministic parser returning a realistic Indian day.
class FakeFoodLogParser implements FoodLogParser {
  FakeFoodLogParser({this.result, this.delay = Duration.zero});
  final FoodLogParseResult? result;
  final Duration delay;
  final calls = <(String, bool)>[];

  @override
  bool get isConfigured => true;

  @override
  bool get supportsFastMode => true;

  @override
  Future<FoodLogParseResult> parse(
    String text, {
    required DateTime now,
    bool fast = false,
  }) async {
    calls.add((text, fast));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return result ?? sampleParse;
  }
}

ParsedFoodItem _p(
  String name,
  String qty,
  double g,
  double kcal,
  double p,
  double c,
  double f,
  MealType m, {
  double conf = 0.8,
  String? note,
}) => ParsedFoodItem(
  name: name,
  quantityDescription: qty,
  grams: g,
  nutrients: Nutrients(calories: kcal, protein: p, carbs: c, fat: f, fiber: 1),
  mealType: m,
  confidence: conf,
  note: note,
);

final sampleParse = FoodLogParseSuccess(
  [
    _p(
      'Egg omelette',
      '3 eggs',
      165,
      290,
      19,
      2,
      23,
      MealType.breakfast,
      note: 'assumed 1 tsp oil',
    ),
    _p('Roti', '2 rotis', 80, 240, 8, 44, 4, MealType.breakfast),
    _p(
      'Paneer bhurji',
      '100 g',
      120,
      330,
      19,
      7,
      25,
      MealType.lunch,
      conf: 0.4,
    ),
  ],
  unparsed: ['felt bloated'],
  provider: 'gemini',
);

Widget _app(
  AppDatabase db,
  FoodLogParser? parser, {
  String? text,
}) => ProviderScope(
  overrides: [
    ...testOverrides(db, now: _now),
    if (parser != null) foodLogParserProvider.overrideWithValue(parser),
    // AI values only here (grounding is covered in indian_food_db_test).
    indianFoodDbProvider.overrideWithValue(IndianFoodDb.fromCsv('Dish Name')),
  ],
  child: MaterialApp(
    theme: AppTheme.dark(),
    home: AiFoodLogScreen(initialText: text),
  ),
);

Future<void> _pump(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('input → review shows charts, then Log all writes rows', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    // Something already logged today feeds the impact bars.
    await FoodLogRepository(db, FixedClock(_now)).quickAdd(
      name: 'Tea',
      nutrients: const Nutrients(calories: 1500, protein: 40),
      mealType: MealType.snack,
      localDate: _today,
    );
    final parser = FakeFoodLogParser();
    await tester.pumpWidget(_app(db, parser, text: sampleDayLog));
    await _pump(tester);

    expect(find.text('Tell JARVIS'), findsWidgets);
    expect(find.byKey(const Key('ai-log-field')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-log-analyse')));
    await _pump(tester, 10);

    expect(parser.calls.single.$1, sampleDayLog);
    expect(find.text('Log all 3 items'), findsOneWidget);
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.byType(MacroDonut), findsOneWidget);
    expect(find.byType(ItemCaloriesChart), findsOneWidget);
    expect(find.byType(ImpactBar), findsNWidgets(4));
    expect(find.text('Impact on today'), findsOneWidget);
    // 1500 + 860 = 2360 of the default 2000 kcal target: over.
    expect(find.textContaining('Over by'), findsWidgets);
    expect(find.text('Paneer bhurji'), findsWidgets);
    expect(find.text('“felt bloated”'), findsOneWidget);
    expect(find.text('Search instead'), findsOneWidget);
    // Nothing is written before the user commits.
    expect(
      await FoodLogRepository(db, FixedClock(_now)).day(_today),
      hasLength(1),
    );

    await tester.tap(find.byKey(const Key('ai-log-commit')));
    await _pump(tester, 12);
    final rows = await FoodLogRepository(db, FixedClock(_now)).day(_today);
    expect(rows, hasLength(4));
    final ai = rows.where((r) => r.source == FoodSources.aiEstimate).toList();
    expect(ai, hasLength(3));
    expect(ai.every((r) => r.verification == Verifications.estimate), isTrue);
    expect(ai.firstWhere((r) => r.name == 'Roti').mealType, 'breakfast');
    await settleAndDispose(tester);
  });

  testWidgets('editing an item rescales it; removing drops it from Log all', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(_app(db, FakeFoodLogParser(), text: '2 rotis'));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('ai-log-analyse')));
    await _pump(tester, 10);

    await tester.tap(find.text('Roti').last);
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('ai-edit-grams')), '160');
    await _pump(tester, 2);
    await tester.tap(find.byKey(const Key('ai-edit-save')));
    await _pump(tester);
    expect(find.text('480'), findsWidgets); // 240 kcal × 2

    await tester.tap(find.text('Egg omelette').last);
    await _pump(tester);
    await tester.tap(find.text('Remove'));
    await _pump(tester);
    expect(find.text('Log all 2 items'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('fast mode is the default; failure offers precise mode', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    final parser = FakeFoodLogParser(
      result: const FoodLogParseFailure('The AI timed out.', timedOut: true),
    );
    await tester.pumpWidget(_app(db, parser, text: 'dal chawal'));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('ai-log-analyse')));
    await _pump(tester);
    expect(find.text('That took too long'), findsOneWidget);
    expect(parser.calls.first.$2, isTrue, reason: 'Groq first by default');
    expect(find.byKey(const Key('ai-log-fast')), findsNothing);
    await tester.tap(find.byKey(const Key('ai-log-precise')));
    await _pump(tester);
    expect(parser.calls.last.$2, isFalse, reason: 'precise = Gemini first');
    await settleAndDispose(tester);
  });

  testWidgets('analysing can be cancelled and nothing is logged', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    final parser = FakeFoodLogParser(delay: const Duration(seconds: 5));
    await tester.pumpWidget(_app(db, parser, text: 'dal chawal'));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('ai-log-analyse')));
    await _pump(tester);
    expect(find.textContaining('ANALYSING'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ai-log-cancel')));
    await _pump(tester);
    expect(find.byKey(const Key('ai-log-field')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Log all 3 items'), findsNothing);
    await settleAndDispose(tester);
  });

  testWidgets('unconfigured AI is honest and offers the offline parser', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(_app(db, null, text: '2 rotis'));
    await _pump(tester);
    expect(find.byKey(const Key('ai-log-analyse')), findsNothing);
    expect(find.byKey(const Key('ai-log-offline')), findsOneWidget);
    expect(find.textContaining('AI is offline in this build'), findsOneWidget);
    expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);
    await settleAndDispose(tester);
  });
}
