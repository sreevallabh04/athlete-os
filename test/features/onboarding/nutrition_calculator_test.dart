import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/domain/nutrition_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void within(num actual, num expected, double pct) => expect(
    (actual - expected).abs() <= expected.abs() * pct / 100,
    isTrue,
    reason: '$actual not within $pct % of $expected',
  );

  group('calculateNutrition — Sreevallabh (78 kg, 19 % BF)', () {
    final plan = calculateNutrition(
      CalibrationAnswers.interviewDefaults().nutritionInputs,
    );

    test('reproduces the agreed targets within 2 %', () {
      // Agreed 2026-10-26: 2,000 kcal at 0.9 % BW/week.
      within(plan.targetKcal, 2000, 2);
      within(plan.proteinG, 170, 2);
      within(plan.fatG, 65, 2);
      within(plan.carbsG, 185, 2);
      expect(plan.targetKcal, 2000);
      expect(plan.proteinG, 170);
      expect(plan.fatG, 65);
      expect(plan.carbsG, 185);
    });

    test('intermediate values are physiologically sensible', () {
      expect(plan.lbmKg, closeTo(63.18, 0.01));
      expect(plan.bmr, closeTo(370 + 21.6 * 63.18, 0.5));
      expect(plan.maintenanceLow, 2700);
      expect(plan.maintenanceHigh, 2850);
      expect(plan.maintenance, inInclusiveRange(2700, 2850));
      expect(plan.activityMultiplier, inInclusiveRange(1.5, 1.7));
      // 0.9 % BW/week (user's choice): a 27.5 % deficit, so the plan
      // carries an honest caution rather than silently allowing it.
      expect(plan.deficitPct, closeTo(27.5, 0.5));
      expect(plan.weeklyChangeKg, closeTo(-0.702, 0.001));
      expect(plan.warnings, isNotEmpty);
    });

    test('stage weight and prep length estimates', () {
      expect(plan.stageWeightHighKg, closeTo(68.7, 0.1));
      expect(plan.stageWeightLowKg, closeTo(67.2, 0.1));
      expect(plan.prepWeeksMin, lessThanOrEqualTo(20));
      expect(plan.prepWeeksMax, inInclusiveRange(15, 19));
    });

    test('macros add up to the calorie target (±1 %)', () {
      final kcal = plan.proteinG * 4 + plan.carbsG * 4 + plan.fatG * 9;
      within(kcal, plan.targetKcal, 1);
    });
  });

  group('guardrails', () {
    test('never below 1,500 kcal without a warning', () {
      final p = calculateNutrition(
        const NutritionInputs(
          weightKg: 50,
          bodyFatPct: 25,
          liftDaysPerWeek: 0,
          runDaysPerWeek: 0,
          dailySteps: 3000,
          weeklyRatePct: 1.5,
        ),
      );
      expect(p.targetKcal, 1500);
      expect(p.warnings, contains(NutritionWarning.belowFloor));
      expect(p.warnings, contains(NutritionWarning.fastRate));
    });

    test('deficit above 25 % is flagged', () {
      final p = calculateNutrition(
        const NutritionInputs(weightKg: 110, bodyFatPct: 30, weeklyRatePct: 1),
      );
      expect(p.deficitPct, greaterThan(25));
      expect(p.warnings, contains(NutritionWarning.largeDeficit));
    });

    test('fat never below 0.8 g/kg or 20 % of kcal', () {
      final p = calculateNutrition(
        const NutritionInputs(weightKg: 80, bodyFatPct: 15, fatPerKgBw: 0.4),
      );
      expect(p.fatG, greaterThanOrEqualTo(64));
      expect(p.fatG * 9, greaterThanOrEqualTo(p.targetKcal * 0.2));
      expect(p.warnings, contains(NutritionWarning.fatFloor));
    });

    test('lean bulk adds a surplus; recomp is a small deficit', () {
      final bulk = calculateNutrition(
        const NutritionInputs(
          weightKg: 78,
          bodyFatPct: 12,
          goal: NutritionGoal.leanBulk,
          weeklyRatePct: 0.25,
        ),
      );
      expect(bulk.targetKcal, greaterThan(bulk.maintenance));
      final recomp = calculateNutrition(
        const NutritionInputs(
          weightKg: 78,
          bodyFatPct: 19,
          goal: NutritionGoal.recomp,
        ),
      );
      expect(recomp.deficitPct, closeTo(5, 1.5));
    });
  });

  group('weeklyAdjustment', () {
    List<WeightReading> series(double prev, double cur) => [
      for (var d = 7; d <= 13; d++)
        WeightReading('2026-10-${(25 - d).toString().padLeft(2, '0')}', prev),
      for (var d = 0; d <= 6; d++)
        WeightReading('2026-10-${(25 - d).toString().padLeft(2, '0')}', cur),
    ];

    test('stalled loss proposes −150 kcal', () {
      final r = weeklyAdjustment(
        readings: series(78, 78),
        today: '2026-10-25',
        targetRatePct: -0.6,
      );
      expect(r.verdict, AdjustmentVerdict.tooSlow);
      expect(r.deltaKcal, -150);
    });

    test('slow loss proposes −100 kcal', () {
      final r = weeklyAdjustment(
        readings: series(78, 77.85),
        today: '2026-10-25',
        targetRatePct: -0.6,
      );
      expect(r.deltaKcal, -100);
    });

    test('on-track loss holds', () {
      final r = weeklyAdjustment(
        readings: series(78, 77.55),
        today: '2026-10-25',
        targetRatePct: -0.6,
      );
      expect(r.verdict, AdjustmentVerdict.onTrack);
      expect(r.hasProposal, isFalse);
    });

    test('too-fast loss proposes +100/+150', () {
      expect(
        weeklyAdjustment(
          readings: series(78, 77.2),
          today: '2026-10-25',
          targetRatePct: -0.6,
        ).deltaKcal,
        100,
      );
      expect(
        weeklyAdjustment(
          readings: series(78, 76.8),
          today: '2026-10-25',
          targetRatePct: -0.6,
        ).deltaKcal,
        150,
      );
    });

    test('needs enough weigh-ins', () {
      final r = weeklyAdjustment(
        readings: const [WeightReading('2026-10-25', 78)],
        today: '2026-10-25',
        targetRatePct: -0.6,
      );
      expect(r.verdict, AdjustmentVerdict.insufficientData);
    });

    test('applyKcalDelta keeps protein/fat and moves carbs', () {
      final r = applyKcalDelta(
        kcal: 2250,
        proteinG: 170,
        fatG: 65,
        deltaKcal: -100,
      );
      expect(r.kcal, 2150);
      expect(r.carbsG, 220);
    });
  });
}
