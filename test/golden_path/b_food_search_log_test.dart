import 'dart:convert';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/presentation/add_food_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/nutrition_screen.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:athlete_os/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_app.dart';
import 'golden_helpers.dart';

/// Fake Open Food Facts: one complete product, 100 g serving.
/// 250 kcal · 20 g protein · 10 g carbs · 15 g fat per serving.
MockClient fakeOpenFoodFacts(List<Uri> calls) => MockClient((req) async {
  calls.add(req.url);
  if (req.url.path != '/cgi/search.pl') return http.Response('{}', 404);
  return http.Response(
    jsonEncode({
      'count': 1,
      'products': [
        {
          'code': '8900000000017',
          'product_name': 'Golden Paneer Tikka',
          'brands': 'Test Dairy',
          'serving_size': '100 g',
          'serving_quantity': 100,
          'serving_quantity_unit': 'g',
          'nutriments': {
            'energy-kcal_100g': 250,
            'proteins_100g': 20,
            'carbohydrates_100g': 10,
            'fat_100g': 15,
            'fiber_100g': 0,
          },
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
});

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('search Open Food Facts → Save & log → Nutrition and Today '
      'reflect the entry', (tester) async {
    useTallView(tester, size: const Size(1080, 4800));
    final calls = <Uri>[];
    final container = goldenContainer(
      db,
      extra: [
        nutritionHttpClientProvider.overrideWithValue(fakeOpenFoodFacts(calls)),
      ],
    );

    await tester.pumpWidget(
      hostIn(
        container,
        const AddFoodScreen(initialMeal: 'lunch', initialDate: goldenToday),
      ),
    );
    await pumpFrames(tester, count: 2, step: const Duration(milliseconds: 100));

    await tester.enterText(
      find.byKey(const Key('food-search-field')),
      'paneer',
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Remote search runs only on explicit submit.
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 800)); // button expands
    await tester.tap(find.text('Search Open Food Facts for "paneer"'));
    await pumpUntil(tester, find.text('Golden Paneer Tikka'));
    expect(calls, hasLength(1));
    expect(calls.single.queryParameters['search_terms'], 'paneer');

    await tester.tap(find.text('Golden Paneer Tikka').first);
    await pumpUntil(tester, find.text('Save & log'));
    await tester.pump(const Duration(milliseconds: 400)); // sheet entrance
    await tester.tap(find.text('Save & log'));
    await pumpFrames(tester);

    // Exactly one persisted entry with the per-serving values.
    final rows = await db.select(db.foodLogEntries).get();
    expect(rows, hasLength(1));
    final e = rows.single;
    expect(e.name, 'Golden Paneer Tikka');
    expect(e.localDate, goldenToday);
    expect(e.mealType, 'lunch');
    expect(e.calories, 250);
    expect(e.proteinG, 20);
    expect(e.source, FoodSources.openFoodFacts);
    expect(await db.select(db.foods).get(), hasLength(1));

    // Nutrition providers.
    final day = await readAsync(
      tester,
      container,
      dayEntriesProvider(goldenToday),
      until: (v) => v.isNotEmpty,
    );
    expect(day.single.id, e.id);

    // Today snapshot provider (feeds the reactor rings).
    final snap = await readAsync(
      tester,
      container,
      todaySnapshotProvider,
      until: (s) => s.nutrition.entries > 0,
    );
    expect(snap.nutrition.kcal, 250);
    expect(snap.nutrition.proteinG, 20);
    expect(snap.mealsLogged, 1);

    // Nutrition screen day totals.
    await tester.pumpWidget(hostIn(container, const NutritionScreen()));
    await pumpFrames(tester, count: 4);
    expect(find.text('250 / 2,000'), findsOneWidget);

    // Today reactor legend: remaining = target − logged.
    await tester.pumpWidget(hostIn(container, const TodayScreen()));
    await pumpFrames(tester);
    expect(find.text('1,750 left'), findsOneWidget); // 2,000 − 250 kcal
    expect(find.text('130 g to go'), findsOneWidget); // 150 − 20 g protein
    expect(find.text('NOT LOGGED'), findsOneWidget, reason: 'only water');

    await driftTeardown(tester);
  });
}
