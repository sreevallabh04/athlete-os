import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/features/nutrition/application/ai_food_log.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_parser.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_review.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/domain/nutrition_calc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

final _now = DateTime(2026, 10, 26, 13, 30); // lunch time

ParsedFoodItem _item(
  String name, {
  double kcal = 100,
  double p = 5,
  double c = 15,
  double f = 2,
  double? fiber,
  double? grams = 100,
  MealType? meal = MealType.lunch,
  double? confidence = 0.8,
  String? quantity,
  String? note,
}) => ParsedFoodItem(
  name: name,
  quantityDescription: quantity,
  grams: grams,
  nutrients: Nutrients(
    calories: kcal,
    protein: p,
    carbs: c,
    fat: f,
    fiber: fiber,
  ),
  mealType: meal,
  confidence: confidence,
  note: note,
);

void main() {
  group('sanitizeFoodLog', () {
    test('drops nameless items, clamps negatives and absurd values', () {
      final s = sanitizeFoodLog([
        _item('  '),
        _item('Paneer', kcal: 9000, p: -3, c: 2, f: 900, grams: 9999),
      ], now: _now);
      expect(s.items, hasLength(1));
      final paneer = s.items.single;
      expect(paneer.nutrients.protein, 0);
      expect(paneer.nutrients.fat, FoodLogLimits.fat);
      expect(paneer.grams, FoodLogLimits.grams);
      expect(paneer.nutrients.calories, lessThanOrEqualTo(FoodLogLimits.kcal));
      expect(paneer.flags, contains(ReviewFlag.clamped));
    });

    test('recomputes kcal when inconsistent with macros (>20 %)', () {
      final s = sanitizeFoodLog([
        // 4*20 + 4*30 + 9*10 = 290 kcal, model said 500.
        _item('Chilla', kcal: 500, p: 20, c: 30, f: 10),
        // 4*5 + 4*15 + 9*2 = 98 vs 100: consistent.
        _item('Roti', kcal: 100),
        // Tiny items are never "fixed" over rounding noise.
        _item('Black coffee', kcal: 5, p: 0.3, c: 0, f: 0),
      ], now: _now);
      final chilla = s.items[0];
      expect(chilla.nutrients.calories, 290);
      expect(chilla.flags, contains(ReviewFlag.kcalRecomputed));
      expect(s.items[1].nutrients.calories, 100);
      expect(s.items[1].flags, isNot(contains(ReviewFlag.kcalRecomputed)));
      expect(s.items[2].nutrients.calories, 5);
      expect(s.adjustedCount, 1);
      expect(
        kcalInconsistent(
          500,
          const Nutrients(calories: 0, protein: 20, carbs: 30, fat: 10),
        ),
        isTrue,
      );
    });

    test('unknown meal falls back to the time of day and is flagged', () {
      final s = sanitizeFoodLog([
        _item('Dal', meal: null),
        _item('Omelette', meal: MealType.breakfast),
      ], now: _now);
      expect(s.items[0].mealType, MealType.lunch);
      expect(s.items[0].flags, contains(ReviewFlag.mealDefaulted));
      expect(s.items[1].mealType, MealType.breakfast);
      final night = sanitizeFoodLog([
        _item('Curd', meal: null),
      ], now: DateTime(2026, 10, 26, 20, 0));
      expect(night.items.single.mealType, MealType.dinner);
    });

    test('removes exact duplicates but keeps the same food in two meals', () {
      final s = sanitizeFoodLog([
        _item('Roti', quantity: '2 rotis'),
        _item('roti', quantity: '2 Rotis'),
        _item('Roti', quantity: '2 rotis', meal: MealType.dinner),
      ], now: _now);
      expect(s.items, hasLength(2));
      expect(s.duplicatesRemoved, 1);
      expect(s.items.map((i) => i.id).toSet(), hasLength(2));
    });

    test('caps text, clamps confidence and cleans unparsed fragments', () {
      final s = sanitizeFoodLog(
        [_item('A' * 200, confidence: 3, note: '  assumed   ghee ')],
        now: _now,
        unparsed: ['gym at 6', '', 'gym at 6'],
      );
      expect(s.items.single.name.length, FoodLogLimits.nameChars);
      expect(s.items.single.confidence, 1);
      expect(s.items.single.note, 'assumed ghee');
      expect(s.unparsed, ['gym at 6']);
    });
  });

  test('scaledToGrams rescales macros proportionally', () {
    final item = sanitizeFoodLog([
      _item('Paneer bhurji', kcal: 300, p: 18, c: 6, f: 22.7, grams: 100),
    ], now: _now).items.single;
    final bigger = item.scaledToGrams(150);
    expect(bigger.grams, 150);
    expect(bigger.nutrients.protein, 27);
    expect(
      bigger.nutrients.calories,
      closeTo(item.nutrients.calories * 1.5, 0.1),
    );
    expect(bigger.flags, contains(ReviewFlag.edited));
    // No known weight: unchanged.
    final noGrams = sanitizeFoodLog([
      _item('Salad', grams: null),
    ], now: _now).items.single;
    expect(noGrams.scaledToGrams(200).nutrients, noGrams.nutrients);
  });

  test('summary totals, per-meal sums and macro split', () {
    final s = sanitizeFoodLog([
      _item(
        'Omelette',
        kcal: 280,
        p: 19,
        c: 2,
        f: 21,
        meal: MealType.breakfast,
      ),
      _item('Dal', kcal: 180, p: 9, c: 24, f: 5, confidence: 0.3),
      _item('Rice', kcal: 195, p: 4, c: 43, f: 0.5),
    ], now: _now);
    final sum = FoodLogSummary.of(s.items);
    expect(sum.count, 3);
    expect(sum.total.calories, 655);
    expect(sum.total.protein, 32);
    expect(sum.byMeal[MealType.lunch]!.calories, 375);
    expect(sum.meals, [MealType.breakfast, MealType.lunch]);
    expect(sum.lowConfidenceCount, 1);
    final (p, c, f) = sum.split.roundedPercents();
    expect(p + c + f, 100);
  });

  test('impact: before/after vs targets, remaining and over-by', () {
    final impact = FoodLogImpact.compute(
      existing: const Nutrients(calories: 1500, protein: 60),
      added: const Nutrients(calories: 700, protein: 40),
      targets: const NutritionTargets(
        calories: 2000,
        protein: 140,
        carbs: 250,
        fat: 0,
      ),
    );
    expect(impact.calories.after, 2200);
    expect(impact.calories.overAfter, isTrue);
    expect(impact.calories.remainingAfter.overBy, 200);
    expect(impact.calories.crossesTarget, isTrue);
    expect(impact.protein.remainingAfter.value, 40);
    expect(impact.protein.overAfter, isFalse);
    expect(impact.fat.hasTarget, isFalse);
  });

  test('logReviewedItems writes all items in one go as AI estimates', () async {
    final db = newTestDb();
    addTearDown(db.close);
    final repo = FoodLogRepository(db, FixedClock(_now));
    final s = sanitizeFoodLog([
      _item(
        'Omelette',
        meal: MealType.breakfast,
        quantity: '3 eggs',
        note: 'assumed 1 tsp oil',
      ),
      _item('Dal', quantity: '1 katori'),
      _item('Whey', meal: MealType.snack, grams: 30),
    ], now: _now);
    final ids = await logReviewedItems(repo, s.items, localDate: '2026-10-25');
    expect(ids, hasLength(3));
    final rows = await repo.day('2026-10-25');
    expect(rows, hasLength(3));
    expect(rows.every((r) => r.source == FoodSources.aiEstimate), isTrue);
    expect(rows.every((r) => r.verification == Verifications.estimate), isTrue);
    final byName = {for (final r in rows) r.name: r};
    expect(byName['Omelette']!.mealType, 'breakfast');
    expect(byName['Omelette']!.note, '3 eggs · assumed 1 tsp oil');
    expect(byName['Whey']!.mealType, 'snack');
    expect(byName['Whey']!.grams, 30);
    expect(await repo.day('2026-10-26'), isEmpty);
    expect(await repo.logAll(const [], localDate: '2026-10-26'), isEmpty);
  });
}
