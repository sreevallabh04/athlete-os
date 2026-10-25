import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/data/food_repository.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/presentation/add_food_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/describe_meal_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/hydration_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/nutrition_history_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/nutrition_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/widgets/amount_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

final now = DateTime(2026, 10, 25, 13, 30);
const today = '2026-10-25';

Future<void> settleAndDispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('NutritionScreen shows totals, remaining and entries', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    final foods = FoodRepository(db, FixedClock(now));
    final log = FoodLogRepository(db, FixedClock(now));
    final paneer = await foods.create(
      FoodDraft(
        name: 'Paneer',
        basis: ServingBasis.per100g(
          const Nutrients(calories: 250, protein: 20, carbs: 2, fat: 18),
        ),
        source: FoodSources.custom,
        verification: Verifications.userEntered,
      ),
    );
    await log.logFood(
      paneer,
      amount: const Amount.grams(200),
      mealType: MealType.lunch,
      localDate: today,
    );
    await log.quickAdd(
      name: 'Samosa',
      nutrients: const Nutrients(calories: 300, protein: 5),
      mealType: MealType.snack,
      localDate: today,
    );
    // Soft-deleted entries must not count.
    final gone = await log.quickAdd(
      name: 'Deleted cake',
      nutrients: const Nutrients(calories: 900),
      mealType: MealType.snack,
      localDate: today,
    );
    await log.softDelete(gone);

    await tester.pumpWidget(
      testHarness(const NutritionScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.textContaining('FUEL LOG'), findsOneWidget);
    // 500 + 300 = 800 eaten of 2000 -> 1,200 left.
    expect(find.text('800 / 2,000'), findsOneWidget);
    expect(find.text('1,200'), findsOneWidget);
    expect(find.text('KCAL LEFT'), findsOneWidget);
    expect(find.text('Paneer'), findsOneWidget);
    expect(find.text('Samosa'), findsOneWidget);
    expect(find.text('Deleted cake'), findsNothing);
    expect(find.text('ESTIMATE'), findsOneWidget);
    expect(find.textContaining('Includes 1 estimated item'), findsOneWidget);
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Edit targets'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('NutritionScreen shows "over by" when above target', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await FoodLogRepository(db, FixedClock(now)).quickAdd(
      name: 'Feast',
      nutrients: const Nutrients(calories: 2500),
      mealType: MealType.dinner,
      localDate: today,
      isEstimate: false,
    );
    await tester.pumpWidget(
      testHarness(const NutritionScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('500'), findsOneWidget);
    expect(find.text('KCAL OVER'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('NutritionScreen empty state', (tester) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(const NutritionScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Nothing logged yet today'), findsOneWidget);
    expect(find.text('2,000'), findsOneWidget); // all kcal left
    expect(find.text('ESTIMATE'), findsNothing);
    await settleAndDispose(tester);
  });

  testWidgets('HydrationScreen shows total vs goal and quick-add works', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await WaterRepository(db, FixedClock(now)).add(500);
    await tester.pumpWidget(
      testHarness(const HydrationScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('500 ml'), findsWidgets);
    expect(find.text('2.5 L to go'), findsOneWidget);
    await tester.tap(find.text('+250 ml'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('750 ml'), findsWidgets);
    expect(find.textContaining('Your goal'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('History empty state never treats missing days as zero', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(const NutritionHistoryScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('No food logged in this period'), findsOneWidget);
    expect(find.text('No weight data in this period'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('History shows averages over logged days only', (tester) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    final log = FoodLogRepository(db, FixedClock(now));
    await log.quickAdd(
      name: 'A',
      nutrients: const Nutrients(calories: 2000, protein: 150),
      mealType: MealType.lunch,
      localDate: today,
      isEstimate: false,
    );
    await log.quickAdd(
      name: 'B',
      nutrients: const Nutrients(calories: 1000, protein: 50),
      mealType: MealType.lunch,
      localDate: '2026-10-23',
      isEstimate: false,
    );
    await tester.pumpWidget(
      testHarness(const NutritionHistoryScreen(), db: db, now: now),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.textContaining('2 of 7 days logged'), findsOneWidget);
    expect(find.text('1,500'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('AddFoodScreen renders tabs with meal from query param', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(
        const AddFoodScreen(initialMeal: 'dinner', initialDate: today),
        db: db,
        now: now,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    for (final t in ['Search', 'Recent', 'Favorites', 'My foods', 'Meals']) {
      expect(find.text(t), findsWidgets);
    }
    final picker = tester.widget<MealPicker>(find.byType(MealPicker));
    expect(picker.value, MealType.dinner);
    expect(find.text('Scan barcode'), findsOneWidget);
    await settleAndDispose(tester);
  });

  testWidgets('Describe meal matches local foods and lists lookups', (
    tester,
  ) async {
    useTallView(tester);
    final db = newTestDb();
    addTearDown(db.close);
    await FoodRepository(db, FixedClock(now)).create(
      FoodDraft(
        name: 'Paneer',
        basis: ServingBasis.per100g(
          const Nutrients(calories: 265, protein: 18.3, carbs: 1.2, fat: 20.8),
        ),
        source: FoodSources.custom,
        verification: Verifications.userEntered,
      ),
    );
    await tester.pumpWidget(
      testHarness(
        const DescribeMealScreen(meal: MealType.lunch, date: today),
        db: db,
        now: now,
      ),
    );
    await tester.enterText(
      find.byKey(const Key('describe-field')),
      '150 g paneer and 2 idli',
    );
    await tester.tap(find.byKey(const Key('describe-parse')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Paneer · 150 g'), findsOneWidget);
    expect(find.text('Needs lookup: idli'), findsOneWidget);
    expect(find.text('Log 1 item to Lunch'), findsOneWidget);

    // AI fallback reports honestly that it is not configured.
    await tester.tap(find.text('Estimate unmatched items with AI'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('AI estimation unavailable (AI backend not configured)'),
      findsOneWidget,
    );
    await settleAndDispose(tester);
  });
}
