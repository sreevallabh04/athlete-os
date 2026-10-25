import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/domain/nutrition_calc.dart';
import 'package:flutter_test/flutter_test.dart';

const paneer100 = Nutrients(
  calories: 265,
  protein: 18.3,
  carbs: 1.2,
  fat: 20.8,
  fiber: 0,
);

LogLine line(
  String date,
  String meal,
  Nutrients n, {
  bool deleted = false,
  String verification = Verifications.userEntered,
  String name = 'x',
  String? foodId,
}) => LogLine(
  localDate: date,
  mealType: meal,
  nutrients: n,
  deleted: deleted,
  verification: verification,
  name: name,
  foodId: foodId,
);

const targets = NutritionTargets(
  calories: 2000,
  protein: 150,
  carbs: 200,
  fat: 60,
);

void main() {
  group('Nutrients', () {
    test('adds and keeps unknown fiber as null only when both unknown', () {
      const a = Nutrients(calories: 100, protein: 10);
      const b = Nutrients(calories: 50, carbs: 5, fiber: 2);
      expect((a + a).fiber, isNull);
      final s = a + b;
      expect(s.calories, 150);
      expect(s.protein, 10);
      expect(s.carbs, 5);
      expect(s.fiber, 2);
    });

    test('round1 rounds half away from zero and handles NaN', () {
      expect(round1(1.25), 1.3);
      expect(round1(1.24), 1.2);
      expect(round1(-1.25), -1.3);
      expect(round1(double.nan), 0);
    });

    test('rounded() rounds every field to 1 dp', () {
      const n = Nutrients(
        calories: 397.456,
        protein: 27.449,
        carbs: 1.85,
        fat: 31.2,
        fiber: 0.04,
      );
      expect(
        n.rounded(),
        const Nutrients(
          calories: 397.5,
          protein: 27.4,
          carbs: 1.9,
          fat: 31.2,
          fiber: 0,
        ),
      );
    });
  });

  group('scaling', () {
    final per100 = ServingBasis.per100g(paneer100);

    test('by grams for a per-100 g food', () {
      final n = nutrientsForGrams(per100, 150);
      expect(n.calories, closeTo(397.5, 1e-9));
      expect(n.protein, closeTo(27.45, 1e-9));
    });

    test('by servings', () {
      const bar = ServingBasis(
        perServing: Nutrients(calories: 180, protein: 20, carbs: 15, fat: 5),
        servingSize: 1,
        servingUnit: 'piece',
        gramsPerServing: 40,
      );
      expect(nutrientsForServings(bar, 1.5).calories, 270);
      expect(nutrientsForGrams(bar, 20).protein, 10);
      expect(bar.servingLabel, '1 piece (40 g)');
    });

    test('grams without gramsPerServing throws', () {
      const s = ServingBasis(
        perServing: Nutrients(calories: 100),
        servingSize: 1,
        servingUnit: 'serving',
      );
      expect(s.supportsGrams, isFalse);
      expect(() => nutrientsForGrams(s, 10), throwsStateError);
    });

    test('negative amounts are rejected', () {
      expect(() => nutrientsForServings(per100, -1), throwsArgumentError);
      expect(() => nutrientsForGrams(per100, -5), throwsArgumentError);
    });

    test('zero amount yields zero nutrients', () {
      expect(nutrientsForGrams(per100, 0).calories, 0);
    });

    test('resolveAmount converts between servings and grams', () {
      final g = resolveAmount(per100, const Amount.grams(250));
      expect(g.servings, 2.5);
      expect(g.grams, 250);
      final s = resolveAmount(per100, const Amount.servings(2));
      expect(s.grams, 200);
      expect(s.nutrients.calories, 530);
    });

    test('ml basis reports ml as base unit', () {
      final milk = ServingBasis.per100g(
        const Nutrients(calories: 62),
        unit: 'ml',
      );
      expect(milk.baseUnit, 'ml');
      expect(nutrientsForGrams(milk, 250).calories, 155);
    });
  });

  group('DayTotals', () {
    test('sums entries per meal and excludes soft-deleted rows', () {
      final t = DayTotals.fromLines([
        line('d', 'breakfast', const Nutrients(calories: 300, protein: 20)),
        line('d', 'lunch', const Nutrients(calories: 600, protein: 40)),
        line(
          'd',
          'lunch',
          const Nutrients(calories: 999, protein: 99),
          deleted: true,
        ),
        line(
          'd',
          'snack',
          const Nutrients(calories: 150),
          verification: Verifications.estimate,
        ),
      ]);
      expect(t.total.calories, 1050);
      expect(t.total.protein, 60);
      expect(t.byMeal[MealType.lunch]!.calories, 600);
      expect(t.byMeal[MealType.dinner]!.calories, 0);
      expect(t.entryCount, 3);
      expect(t.estimateCount, 1);
    });

    test('empty day', () {
      final t = DayTotals.fromLines(const []);
      expect(t.isEmpty, isTrue);
      expect(t.total, Nutrients.zero);
    });

    test('unknown meal keys go to snacks', () {
      final t = DayTotals.fromLines([
        line('d', 'brunch', const Nutrients(calories: 10)),
      ]);
      expect(t.byMeal[MealType.snack]!.calories, 10);
    });
  });

  group('Remaining', () {
    test('remaining and over-by are not clamped', () {
      final r = RemainingSummary.compute(
        const Nutrients(calories: 2250, protein: 120),
        targets,
      );
      expect(r.calories.value, -250);
      expect(r.calories.isOver, isTrue);
      expect(r.calories.overBy, 250);
      expect(r.calories.visualProgress, 1.0);
      expect(r.calories.ratio, 1.125);
      expect(r.protein.value, 30);
      expect(r.protein.isOver, isFalse);
      expect(r.calories.label((v) => v.round().toString()), 'over by 250');
      expect(r.protein.label((v) => v.round().toString()), '30 left');
    });

    test('zero or missing targets mean "no target"', () {
      final r = RemainingSummary.compute(
        const Nutrients(calories: 500, fiber: 10),
        const NutritionTargets(calories: 0, protein: 0, carbs: 0, fat: 0),
      );
      expect(r.calories.hasTarget, isFalse);
      expect(r.calories.value, isNull);
      expect(r.calories.isOver, isFalse);
      expect(r.calories.visualProgress, 0);
      expect(r.fiber.hasTarget, isFalse);
      expect(r.calories.label((v) => '$v'), 'No target set');
    });

    test('ringProgress clamps only for visuals', () {
      expect(ringProgress(50, 100), 0.5);
      expect(ringProgress(150, 100), 1.0);
      expect(ringProgress(-5, 100), 0);
      expect(ringProgress(5, null), 0);
      expect(ringProgress(5, 0), 0);
    });
  });

  group('MacroSplit', () {
    test('uses 4/4/9 and percentages of macro energy', () {
      final s = MacroSplit.of(
        const Nutrients(calories: 0, protein: 100, carbs: 100, fat: 44.44),
      );
      expect(s.proteinKcal, 400);
      expect(s.fatKcal, closeTo(399.96, 1e-9));
      expect(s.proteinPct + s.carbsPct + s.fatPct, closeTo(100, 1e-9));
    });

    test('rounded percents always sum to 100', () {
      // 1/3 each would round to 33+33+33 = 99 naively.
      final s = MacroSplit.of(
        const Nutrients(calories: 0, protein: 9, carbs: 9, fat: 4),
      );
      final (p, c, f) = s.roundedPercents();
      expect(p + c + f, 100);
      expect([p, c, f]..sort(), [33, 33, 34]);
    });

    test('empty split is all zero', () {
      final s = MacroSplit.of(Nutrients.zero);
      expect(s.isEmpty, isTrue);
      expect(s.roundedPercents(), (0, 0, 0));
      expect(s.proteinPct, 0);
    });
  });

  group('Adherence', () {
    test('protein: >= 90% of target counts, above target counts', () {
      expect(Adherence.protein(135, 150), isTrue);
      expect(Adherence.protein(134.9, 150), isFalse);
      expect(Adherence.protein(220, 150), isTrue);
      expect(Adherence.protein(10, 0), isFalse);
    });

    test('calories: within ±10%', () {
      expect(Adherence.calories(1800, 2000), isTrue);
      expect(Adherence.calories(2200, 2000), isTrue);
      expect(Adherence.calories(2201, 2000), isFalse);
      expect(Adherence.calories(1799, 2000), isFalse);
      expect(Adherence.calories(0, 0), isFalse);
    });
  });

  group('PeriodAverages', () {
    test('averages only logged days and reports logged-day count', () {
      final dates = ['d1', 'd2', 'd3', 'd4'];
      final days = summarizeDays(dates, [
        line('d1', 'lunch', const Nutrients(calories: 2000, protein: 150)),
        line('d3', 'lunch', const Nutrients(calories: 1000, protein: 50)),
        line(
          'd4',
          'lunch',
          const Nutrients(calories: 5000, protein: 500),
          deleted: true,
        ),
      ]);
      final a = PeriodAverages.compute(days, targets);
      expect(a.totalDays, 4);
      expect(a.loggedDays, 2);
      expect(a.average.calories, 1500);
      expect(a.average.protein, 100);
      expect(a.proteinAdherentDays, 1);
      expect(a.calorieAdherentDays, 1);
      expect(a.proteinAdherencePct, 50);
      expect(a.average.fiber, isNull);
    });

    test('no logged days', () {
      final a = PeriodAverages.compute(
        summarizeDays(['d1'], const []),
        targets,
      );
      expect(a.hasData, isFalse);
      expect(a.average, Nutrients.zero);
      expect(a.proteinAdherencePct, 0);
    });

    test('fiber averages over days that report fiber', () {
      final days = summarizeDays(
        ['a', 'b'],
        [
          line('a', 'lunch', const Nutrients(calories: 100, fiber: 10)),
          line('b', 'lunch', const Nutrients(calories: 100)),
        ],
      );
      expect(PeriodAverages.compute(days, targets).average.fiber, 10);
    });
  });

  group('weeklyAverages', () {
    test('groups by Monday-start week, averaging logged days only', () {
      // 2026-10-19 is a Monday.
      final dates = [
        '2026-10-18', // Sunday (previous week)
        '2026-10-19',
        '2026-10-20',
        '2026-10-25', // Sunday
      ];
      final days = summarizeDays(dates, [
        line('2026-10-18', 'lunch', const Nutrients(calories: 1000)),
        line('2026-10-19', 'lunch', const Nutrients(calories: 2000)),
        line('2026-10-25', 'lunch', const Nutrients(calories: 1000)),
      ]);
      final w = weeklyAverages(days, targets, LocalDates.weekStart);
      expect(w.keys.toList(), ['2026-10-12', '2026-10-19']);
      expect(w['2026-10-12']!.average.calories, 1000);
      expect(w['2026-10-19']!.loggedDays, 2);
      expect(w['2026-10-19']!.totalDays, 3);
      expect(w['2026-10-19']!.average.calories, 1500);
    });
  });

  group('protein efficiency', () {
    test('g protein per 100 kcal', () {
      expect(
        proteinPer100Kcal(const Nutrients(calories: 200, protein: 25)),
        12.5,
      );
      expect(proteinPer100Kcal(const Nutrients(calories: 0, protein: 5)), null);
    });

    test('ranks usual foods and excludes zero-energy and one-offs', () {
      final lines = [
        line(
          'a',
          'lunch',
          const Nutrients(calories: 265, protein: 18.3),
          name: 'Paneer',
          foodId: 'p',
        ),
        line(
          'b',
          'lunch',
          const Nutrients(calories: 265, protein: 18.3),
          name: 'Paneer',
          foodId: 'p',
        ),
        line(
          'a',
          'breakfast',
          const Nutrients(calories: 70, protein: 6),
          name: 'Egg',
          foodId: 'e',
        ),
        line(
          'b',
          'breakfast',
          const Nutrients(calories: 70, protein: 6),
          name: 'Egg',
          foodId: 'e',
        ),
        line(
          'a',
          'lunch',
          const Nutrients(calories: 130, protein: 2.7),
          name: 'Rice',
          foodId: 'r',
        ),
        line('a', 'snack', const Nutrients(calories: 0), name: 'Black coffee'),
        line('b', 'snack', const Nutrients(calories: 0), name: 'black coffee'),
      ];
      final usual = usualFoods(lines);
      expect(usual.map((u) => u.name), containsAll(['Paneer', 'Egg']));
      expect(usual.any((u) => u.name == 'Rice'), isFalse);
      final ranked = rankByProteinEfficiency(usual);
      expect(ranked.map((r) => r.name).toList(), ['Egg', 'Paneer']);
      expect(ranked.first.timesLogged, 2);
      expect(ranked.first.proteinEfficiency, closeTo(8.571, 1e-3));
    });

    test('ties break by name', () {
      final r = rankByProteinEfficiency(const [
        NamedNutrients(
          name: 'b',
          nutrients: Nutrients(calories: 100, protein: 5),
        ),
        NamedNutrients(
          name: 'a',
          nutrients: Nutrients(calories: 100, protein: 5),
        ),
      ]);
      expect(r.map((e) => e.name).toList(), ['a', 'b']);
    });
  });

  group('HydrationSummary', () {
    test('totals and remaining', () {
      final h = HydrationSummary.fromAmounts([250, 500, 150], 3000);
      expect(h.totalMl, 900);
      expect(h.remainingMl, 2100);
      expect(h.goalReached, isFalse);
      expect(h.visualProgress, closeTo(0.3, 1e-9));
    });

    test('over goal is negative remaining, ring capped', () {
      final h = HydrationSummary.fromAmounts([2000, 1500], 3000);
      expect(h.remainingMl, -500);
      expect(h.goalReached, isTrue);
      expect(h.visualProgress, 1.0);
    });

    test('no goal', () {
      final h = HydrationSummary.fromAmounts([250], 0);
      expect(h.hasGoal, isFalse);
      expect(h.remainingMl, 0);
      expect(h.visualProgress, 0);
    });
  });

  group('recipePerServing', () {
    test('divides the ingredient sum by yield', () {
      final per = recipePerServing(const [
        Nutrients(calories: 397.5, protein: 27.5, carbs: 1.8, fat: 31.2),
        Nutrients(calories: 260, protein: 5.4, carbs: 56, fat: 0.6),
      ], 2);
      expect(per.calories, closeTo(328.75, 1e-9));
      expect(per.protein, closeTo(16.45, 1e-9));
    });

    test('rejects zero servings', () {
      expect(() => recipePerServing(const [], 0), throwsArgumentError);
    });
  });

  group('MealType', () {
    test('default by time of day', () {
      expect(MealType.forTime(DateTime(2026, 1, 1, 7)), MealType.breakfast);
      expect(MealType.forTime(DateTime(2026, 1, 1, 13)), MealType.lunch);
      expect(MealType.forTime(DateTime(2026, 1, 1, 17)), MealType.snack);
      expect(MealType.forTime(DateTime(2026, 1, 1, 20)), MealType.dinner);
      expect(MealType.forTime(DateTime(2026, 1, 1, 23)), MealType.snack);
      expect(MealType.forTime(DateTime(2026, 1, 1, 2)), MealType.snack);
    });

    test('parsing', () {
      expect(MealType.tryParse('lunch'), MealType.lunch);
      expect(MealType.tryParse('x'), isNull);
      expect(MealType.fromKey(null), MealType.snack);
    });
  });

  group('Verifications', () {
    test('weakest level wins', () {
      expect(
        Verifications.weakest([
          Verifications.verifiedLabel,
          Verifications.database,
        ]),
        Verifications.database,
      );
      expect(
        Verifications.weakest([
          Verifications.database,
          Verifications.estimate,
          Verifications.userEntered,
        ]),
        Verifications.estimate,
      );
      expect(Verifications.weakest(const []), Verifications.userEntered);
    });
  });

  group('validateFoodInput', () {
    Map<String, String> v({
      String name = 'Paneer',
      String size = '100',
      String unit = 'g',
      String grams = '',
      String kcal = '265',
      String p = '18.3',
      String c = '1.2',
      String f = '20.8',
      String fiber = '',
      String barcode = '',
    }) => validateFoodInput(
      name: name,
      servingSize: size,
      servingUnit: unit,
      gramsPerServing: grams,
      calories: kcal,
      protein: p,
      carbs: c,
      fat: f,
      fiber: fiber,
      barcode: barcode,
    );

    test('valid input', () => expect(v(), isEmpty));
    test('required fields', () {
      final e = v(name: ' ', kcal: '', p: '');
      expect(e.keys, containsAll(['name', 'calories', 'protein']));
    });
    test('numbers, negatives, comma decimals', () {
      expect(v(p: 'abc')['protein'], 'Enter a number');
      expect(v(f: '-1')['fat'], 'Must be 0 or more');
      expect(v(p: '18,3'), isEmpty);
    });
    test('serving size must be > 0', () {
      expect(v(size: '0')['servingSize'], isNotNull);
    });
    test('implausible calories vs macros', () {
      expect(v(kcal: '10', p: '50', c: '50', f: '20')['calories'], isNotNull);
    });
    test('barcode format', () {
      expect(v(barcode: '12ab')['barcode'], isNotNull);
      expect(v(barcode: '8901058851427'), isEmpty);
    });
  });
}
