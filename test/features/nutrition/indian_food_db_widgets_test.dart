import 'dart:convert';
import 'dart:io';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/ai_food_log.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/data/indian_food_db.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_parser.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/presentation/ai_food_log_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/food_search_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../golden_path/golden_helpers.dart';
import '../../helpers/test_app.dart';
import 'ai_food_log_screen_test.dart' show FakeFoodLogParser;

final _csv = File(indianFoodCsvAsset).readAsStringSync();

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('Indian dishes appear as you type (offline) and log as an '
      'indian_food_db / database Food snapshot', (tester) async {
    useTallView(tester);
    final calls = <Uri>[];
    final indian = IndianFoodDb.fromCsv(_csv);
    await indian.index();
    final container = goldenContainer(
      db,
      extra: [
        indianFoodDbProvider.overrideWithValue(indian),
        nutritionHttpClientProvider.overrideWithValue(
          MockClient((req) async {
            calls.add(req.url);
            return http.Response('{}', 500);
          }),
        ),
      ],
    );
    await tester.pumpWidget(
      hostIn(
        container,
        const Scaffold(
          body: FoodSearchPanel(meal: MealType.breakfast, date: goldenToday),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('food-search-field')), 'chai');
    await pumpUntil(tester, find.text('Hot tea (Garam Chai)'));
    expect(
      find.textContaining('INDIAN DISHES · INDIAN FOOD DB'),
      findsOneWidget,
    );
    expect(find.text('INDIAN FOOD DB'), findsWidgets); // tile badge
    expect(calls, isEmpty); // no network, no rate limit

    await tester.tap(find.text('Hot tea (Garam Chai)'));
    await pumpUntil(tester, find.text('Save & log'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Save & log'));
    await pumpFrames(tester, count: 4);

    final entries = await db.select(db.foodLogEntries).get();
    expect(entries, hasLength(1));
    final e = entries.single;
    expect(e.source, FoodSources.indianFoodDb);
    expect(e.verification, Verifications.database);
    expect(e.mealType, 'breakfast');
    expect(e.calories, closeTo(16.1, 0.1)); // 100 g default
    final food = (await db.select(db.foods).get()).single;
    expect(food.source, FoodSources.indianFoodDb);
    expect(food.gramsPerServing, 100);
    final raw = jsonDecode(food.rawJson!) as Map<String, Object?>;
    expect((raw['per_100g']! as Map)['sodium_mg'], 3.12);
    expect((raw['per_100g']! as Map)['free_sugar_g'], 2.58);

    // Logged once → it is now one of "Your foods", not listed twice.
    await tester.enterText(find.byKey(const Key('food-search-field')), 'chai ');
    await pumpFrames(tester, count: 4);
    expect(find.text('Hot tea (Garam Chai)'), findsOneWidget);
    await driftTeardown(tester);
  });

  testWidgets('AI food log: matched items use DB values with a badge and a '
      'one-tap switch back; unmatched stay estimates', (tester) async {
    useTallView(tester);
    final indian = IndianFoodDb.fromCsv(_csv);
    await indian.index();
    final parser = FakeFoodLogParser(
      result: const FoodLogParseSuccess([
        ParsedFoodItem(
          name: 'Roti',
          quantityDescription: '2 rotis',
          grams: 80,
          nutrients: Nutrients(calories: 240, protein: 8, carbs: 44, fat: 4),
          mealType: MealType.breakfast,
          confidence: 0.8,
        ),
        ParsedFoodItem(
          name: 'Whey protein',
          quantityDescription: '1 scoop',
          grams: 30,
          nutrients: Nutrients(calories: 120, protein: 24, carbs: 3, fat: 1.5),
          mealType: MealType.breakfast,
          confidence: 0.9,
        ),
      ]),
    );
    final container = goldenContainer(
      db,
      extra: [
        indianFoodDbProvider.overrideWithValue(indian),
        foodLogParserProvider.overrideWithValue(parser),
      ],
    );
    await tester.pumpWidget(
      hostIn(
        container,
        const AiFoodLogScreen(initialText: '2 rotis and a scoop of whey'),
      ),
    );
    await pumpFrames(tester, count: 3);
    await tester.tap(find.byKey(const Key('ai-log-analyse')));
    await pumpUntil(tester, find.text('Log all 2 items'));
    await pumpFrames(tester, count: 2);

    expect(find.byKey(const Key('ai-db-grounded')), findsOneWidget);
    expect(find.text('INDIAN FOOD DB'), findsOneWidget);
    expect(find.text('matched: Chapati/Roti'), findsOneWidget);
    expect(find.text('162'), findsWidgets); // 202.31 kcal/100 g × 80 g
    expect(find.text('Use AI estimate'), findsOneWidget);

    // One tap back to the AI estimate, and again to the DB.
    await tester.tap(find.text('Use AI estimate'));
    await pumpFrames(tester, count: 2);
    expect(find.text('INDIAN FOOD DB'), findsNothing);
    expect(find.text('240'), findsWidgets);
    await tester.tap(find.text('Use DB values'));
    await pumpFrames(tester, count: 2);
    expect(find.text('INDIAN FOOD DB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-log-commit')));
    await pumpFrames(tester, count: 8);
    final rows = await db.select(db.foodLogEntries).get();
    expect(rows, hasLength(2));
    final roti = rows.firstWhere((r) => r.name == 'Roti');
    expect(roti.source, FoodSources.indianFoodDb);
    expect(roti.verification, Verifications.database);
    expect(roti.calories, closeTo(161.8, 0.1));
    expect(roti.note, contains('Indian Food DB: Chapati/Roti'));
    final whey = rows.firstWhere((r) => r.name == 'Whey protein');
    expect(whey.source, FoodSources.aiEstimate);
    expect(whey.calories, 120);
    await driftTeardown(tester);
  });
}
