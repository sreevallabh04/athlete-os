/// Deterministic energy & macro calculator used by JARVIS calibration.
///
/// Every number here is an ESTIMATE from population equations, not medical
/// advice. Pure Dart, fully unit-tested.
///
/// Method
/// * Lean body mass (LBM) = weight × (1 − body-fat %).
/// * BMR: Katch-McArdle, `370 + 21.6 × LBM(kg)`.
/// * Baseline: BMR × job factor (desk 1.2, on-feet 1.375, manual 1.55). The
///   factor already covers ~[baselineSteps] steps and thermic effect of food.
/// * Steps above the baseline: 0.04 kcal/step at 70 kg, scaled by weight
///   (≈ 0.5 kcal/kg/km walking).
/// * Lifting: net (MET 5 − 1) × kg × hours (Compendium of Physical
///   Activities, general vigorous resistance training ≈ 5–6 MET).
/// * Running: net (MET 9 − 1) × kg × hours (≈ 8 km/h).
/// * Maintenance range = estimate ±2.5 %, rounded to 50 kcal.
/// * Target = maintenance − weekly loss (% BW × 7,700 kcal/kg ÷ 7), rounded to
///   50 kcal. Lean bulk adds the equivalent surplus.
/// * Protein: g per kg LBM (lean dieters 2.3–3.1, Helms et al. 2014;
///   default 2.7), rounded to 5 g.
/// * Fat: 0.85 g/kg body weight, never below 0.8 g/kg or 20 % of kcal,
///   rounded to 5 g.
/// * Carbs: the remainder, rounded to 5 g.
library;

import 'dart:math' as math;

enum NutritionGoal {
  cut('cut', 'Cut'),
  leanBulk('lean_bulk', 'Lean bulk'),
  recomp('recomp', 'Recomposition'),
  contestPrep('contest_prep', 'Contest prep');

  const NutritionGoal(this.key, this.label);
  final String key;
  final String label;

  bool get isDeficit => this == cut || this == contestPrep;

  static NutritionGoal fromKey(String? key) =>
      values.firstWhere((g) => g.key == key, orElse: () => contestPrep);
}

enum JobActivity {
  desk('desk', 'Desk job', 1.2),
  onFeet('on_feet', 'On my feet', 1.375),
  manual('manual', 'Manual labour', 1.55);

  const JobActivity(this.key, this.label, this.factor);
  final String key;
  final String label;
  final double factor;

  static JobActivity fromKey(String? key) =>
      values.firstWhere((j) => j.key == key, orElse: () => desk);
}

class NutritionInputs {
  const NutritionInputs({
    required this.weightKg,
    required this.bodyFatPct,
    this.liftDaysPerWeek = 5,
    this.liftSessionMinutes = 70,
    this.runDaysPerWeek = 2,
    this.runSessionMinutes = 35,
    this.dailySteps = 12000,
    this.job = JobActivity.desk,
    this.goal = NutritionGoal.contestPrep,
    this.weeklyRatePct = 0.6,
    this.proteinPerKgLbm = 2.7,
    this.fatPerKgBw = 0.85,
  });

  final double weightKg;
  final double bodyFatPct;
  final int liftDaysPerWeek;
  final int liftSessionMinutes;
  final int runDaysPerWeek;
  final int runSessionMinutes;
  final int dailySteps;
  final JobActivity job;
  final NutritionGoal goal;

  /// Planned weekly change as % of body weight (loss for cut/prep, gain for
  /// lean bulk; recomp ignores it).
  final double weeklyRatePct;
  final double proteinPerKgLbm;
  final double fatPerKgBw;
}

enum NutritionWarning {
  belowFloor(
    'Target was raised to the 1,500 kcal floor. Going lower needs '
    'medical supervision.',
  ),
  largeDeficit(
    'Deficit is above 25 % of maintenance — expect more muscle '
    'loss, hunger and fatigue. Consider a slower rate.',
  ),
  fastRate(
    'Losing more than 1 % of body weight per week is aggressive for a '
    'physique athlete.',
  ),
  fatFloor('Fat was raised to the minimum (0.8 g/kg or 20 % of calories).'),
  lowCarbs('Carbohydrates are very low; training quality may suffer.');

  const NutritionWarning(this.message);
  final String message;
}

class NutritionPlan {
  const NutritionPlan({
    required this.lbmKg,
    required this.bmr,
    required this.activityMultiplier,
    required this.maintenance,
    required this.maintenanceLow,
    required this.maintenanceHigh,
    required this.targetKcal,
    required this.dailyDeficit,
    required this.deficitPct,
    required this.proteinG,
    required this.fatG,
    required this.carbsG,
    required this.fiberG,
    required this.weeklyChangeKg,
    required this.stageWeightLowKg,
    required this.stageWeightHighKg,
    required this.prepWeeksMin,
    required this.prepWeeksMax,
    required this.warnings,
  });

  final double lbmKg;
  final double bmr;

  /// Effective TDEE ÷ BMR.
  final double activityMultiplier;
  final int maintenance;
  final int maintenanceLow;
  final int maintenanceHigh;
  final int targetKcal;

  /// Positive = deficit, negative = surplus.
  final int dailyDeficit;
  final double deficitPct;
  final int proteinG;
  final int fatG;
  final int carbsG;
  final int fiberG;

  /// Negative = loss per week.
  final double weeklyChangeKg;

  /// Estimated stage weight at 8 % (high) and 6 % (low) body fat, assuming
  /// lean mass is preserved.
  final double stageWeightLowKg;
  final double stageWeightHighKg;
  final int prepWeeksMin;
  final int prepWeeksMax;
  final List<NutritionWarning> warnings;

  static const disclaimer =
      'Estimates from population equations — not medical advice. Real '
      'maintenance is found by tracking weight for 2–3 weeks; JARVIS will '
      'propose adjustments from your trend.';

  Map<String, Object> toJson() => {
    'lbmKg': lbmKg,
    'bmr': bmr,
    'activityMultiplier': activityMultiplier,
    'maintenance': maintenance,
    'maintenanceLow': maintenanceLow,
    'maintenanceHigh': maintenanceHigh,
    'targetKcal': targetKcal,
    'dailyDeficit': dailyDeficit,
    'deficitPct': deficitPct,
    'proteinG': proteinG,
    'fatG': fatG,
    'carbsG': carbsG,
    'fiberG': fiberG,
    'weeklyChangeKg': weeklyChangeKg,
    'stageWeightLowKg': stageWeightLowKg,
    'stageWeightHighKg': stageWeightHighKg,
    'prepWeeksMin': prepWeeksMin,
    'prepWeeksMax': prepWeeksMax,
    'warnings': [for (final w in warnings) w.name],
  };
}

/// Kcal per kg of body-weight change (fat-tissue convention).
const kcalPerKg = 7700.0;
const minimumKcal = 1500;
const baselineSteps = 5000;

int roundTo(num v, int step) => (v / step).round() * step;

double lbmOf(double weightKg, double bodyFatPct) =>
    weightKg * (1 - bodyFatPct / 100);

double katchMcArdle(double lbmKg) => 370 + 21.6 * lbmKg;

/// Estimated daily exercise + NEAT on top of `BMR × job factor`.
double activityKcal(NutritionInputs i) {
  final extraSteps = math.max(0, i.dailySteps - baselineSteps);
  final steps = extraSteps * 0.04 * (i.weightKg / 70);
  final lift =
      (5.0 - 1) *
      i.weightKg *
      (i.liftSessionMinutes / 60) *
      i.liftDaysPerWeek /
      7;
  final run =
      (9.0 - 1) *
      i.weightKg *
      (i.runSessionMinutes / 60) *
      i.runDaysPerWeek /
      7;
  return steps + lift + run;
}

NutritionPlan calculateNutrition(NutritionInputs i) {
  final lbm = lbmOf(i.weightKg, i.bodyFatPct);
  final bmr = katchMcArdle(lbm);
  final tdee = bmr * i.job.factor + activityKcal(i);
  final maintenance = roundTo(tdee, 10);
  final warnings = <NutritionWarning>[];

  // Energy target.
  final rate = i.weeklyRatePct.abs();
  final weeklyKg = i.weightKg * rate / 100;
  final perDay = weeklyKg * kcalPerKg / 7;
  double rawTarget;
  double weeklyChange;
  switch (i.goal) {
    case NutritionGoal.cut || NutritionGoal.contestPrep:
      rawTarget = tdee - perDay;
      weeklyChange = -weeklyKg;
      if (rate > 1.0) warnings.add(NutritionWarning.fastRate);
    case NutritionGoal.leanBulk:
      rawTarget = tdee + perDay;
      weeklyChange = weeklyKg;
    case NutritionGoal.recomp:
      rawTarget = tdee * 0.95;
      weeklyChange = -(tdee * 0.05 * 7 / kcalPerKg);
  }
  var target = roundTo(rawTarget, 50);
  if (target < minimumKcal) {
    target = minimumKcal;
    warnings.add(NutritionWarning.belowFloor);
  }
  final deficit = (tdee - target).round();
  final deficitPct = deficit / tdee * 100;
  if (deficitPct > 25) warnings.add(NutritionWarning.largeDeficit);

  // Macros.
  final proteinPerKg = i.goal.isDeficit
      ? i.proteinPerKgLbm.clamp(2.3, 3.1)
      : i.proteinPerKgLbm.clamp(1.8, 3.1);
  final protein = roundTo(lbm * proteinPerKg, 5);
  final fatMin = math.max(0.8 * i.weightKg, 0.20 * target / 9);
  var fat = roundTo(i.fatPerKgBw * i.weightKg, 5);
  if (fat < fatMin) {
    fat = (fatMin / 5).ceil() * 5;
    warnings.add(NutritionWarning.fatFloor);
  }
  final carbs = math.max(0, roundTo((target - protein * 4 - fat * 9) / 4, 5));
  if (carbs < 2 * i.weightKg) warnings.add(NutritionWarning.lowCarbs);
  final fiber = roundTo(target / 1000 * 14, 5);

  // Stage estimate (lean mass preserved; real preps lose a little).
  final stageHigh = lbm / (1 - 0.08);
  final stageLow = lbm / (1 - 0.06);
  int weeksTo(double goalKg, double ratePct) {
    if (goalKg >= i.weightKg || ratePct <= 0) return 0;
    return (math.log(goalKg / i.weightKg) / math.log(1 - ratePct / 100)).ceil();
  }

  final prepRate = i.goal.isDeficit && rate > 0 ? rate : 0.6;
  return NutritionPlan(
    lbmKg: lbm,
    bmr: bmr,
    activityMultiplier: tdee / bmr,
    maintenance: maintenance,
    maintenanceLow: roundTo(tdee * 0.975, 50),
    maintenanceHigh: roundTo(tdee * 1.025, 50),
    targetKcal: target,
    dailyDeficit: deficit,
    deficitPct: deficitPct,
    proteinG: protein,
    fatG: fat,
    carbsG: carbs,
    fiberG: fiber,
    weeklyChangeKg: weeklyChange,
    stageWeightLowKg: stageLow,
    stageWeightHighKg: stageHigh,
    prepWeeksMin: weeksTo(stageHigh, prepRate * 1.25),
    prepWeeksMax: weeksTo(stageLow, prepRate),
    warnings: warnings,
  );
}

// ---------------------------------------------------------------------------
// Weekly adjustment
// ---------------------------------------------------------------------------

class WeightReading {
  const WeightReading(this.localDate, this.kg);
  final String localDate;
  final double kg;
}

enum AdjustmentVerdict { insufficientData, onTrack, tooSlow, tooFast }

class KcalAdjustment {
  const KcalAdjustment({
    required this.verdict,
    this.deltaKcal = 0,
    this.actualRatePct,
    this.targetRatePct,
    this.message = '',
  });

  final AdjustmentVerdict verdict;

  /// Proposed change to the daily target (0 = hold).
  final int deltaKcal;

  /// Observed weekly change as % of body weight (negative = loss).
  final double? actualRatePct;
  final double? targetRatePct;
  final String message;

  bool get hasProposal => deltaKcal != 0;
}

/// Compares the latest 7-day average weight with the previous 7-day average
/// and proposes (never applies) a ±100–150 kcal change. [readings] may be in
/// any order; several per day are averaged. [targetRatePct] is the planned
/// weekly change (negative = loss, e.g. −0.6).
KcalAdjustment weeklyAdjustment({
  required List<WeightReading> readings,
  required String today,
  required double targetRatePct,
  int minReadingsPerWeek = 3,
}) {
  String addDays(String key, int days) {
    final p = key.split('-').map(int.parse).toList();
    final d = DateTime(p[0], p[1], p[2] + days);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  final thisStart = addDays(today, -6);
  final prevStart = addDays(today, -13);
  final prevEnd = addDays(today, -7);
  final cur = <double>[];
  final prev = <double>[];
  for (final r in readings) {
    if (r.localDate.compareTo(thisStart) >= 0 &&
        r.localDate.compareTo(today) <= 0) {
      cur.add(r.kg);
    } else if (r.localDate.compareTo(prevStart) >= 0 &&
        r.localDate.compareTo(prevEnd) <= 0) {
      prev.add(r.kg);
    }
  }
  if (cur.length < minReadingsPerWeek || prev.length < minReadingsPerWeek) {
    return KcalAdjustment(
      verdict: AdjustmentVerdict.insufficientData,
      targetRatePct: targetRatePct,
      message:
          'Need at least $minReadingsPerWeek weigh-ins in each of the last two '
          'weeks to judge the trend.',
    );
  }
  double avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
  final a = avg(cur);
  final b = avg(prev);
  final actual = (a - b) / b * 100;
  String pct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} %';

  if (targetRatePct < 0) {
    final want = -targetRatePct;
    final lost = -actual;
    if (lost < want * 0.5) {
      final delta = lost <= 0 ? -150 : -100;
      return KcalAdjustment(
        verdict: AdjustmentVerdict.tooSlow,
        deltaKcal: delta,
        actualRatePct: actual,
        targetRatePct: targetRatePct,
        message:
            '7-day average moved ${pct(actual)} vs a ${pct(targetRatePct)} '
            'target. Suggest $delta kcal/day.',
      );
    }
    if (lost > want * 1.5) {
      final delta = lost > want * 2 ? 150 : 100;
      return KcalAdjustment(
        verdict: AdjustmentVerdict.tooFast,
        deltaKcal: delta,
        actualRatePct: actual,
        targetRatePct: targetRatePct,
        message:
            '7-day average moved ${pct(actual)} — faster than the '
            '${pct(targetRatePct)} target. Suggest +$delta kcal/day to protect '
            'muscle.',
      );
    }
  } else if (targetRatePct > 0) {
    if (actual < targetRatePct * 0.5) {
      return KcalAdjustment(
        verdict: AdjustmentVerdict.tooSlow,
        deltaKcal: 100,
        actualRatePct: actual,
        targetRatePct: targetRatePct,
        message: 'Gaining slower than planned. Suggest +100 kcal/day.',
      );
    }
    if (actual > targetRatePct * 1.5) {
      return KcalAdjustment(
        verdict: AdjustmentVerdict.tooFast,
        deltaKcal: -100,
        actualRatePct: actual,
        targetRatePct: targetRatePct,
        message: 'Gaining faster than planned. Suggest −100 kcal/day.',
      );
    }
  }
  return KcalAdjustment(
    verdict: AdjustmentVerdict.onTrack,
    actualRatePct: actual,
    targetRatePct: targetRatePct,
    message: 'On track (${pct(actual)} this week). Hold targets.',
  );
}

/// New macro split after a kcal change: protein and fat stay, carbs absorb
/// the change (never below 50 g).
({int kcal, int carbsG}) applyKcalDelta({
  required int kcal,
  required int proteinG,
  required int fatG,
  required int deltaKcal,
}) {
  final next = math.max(minimumKcal, kcal + deltaKcal);
  final carbs = math.max(50, roundTo((next - proteinG * 4 - fatG * 9) / 4, 5));
  return (kcal: next, carbsG: carbs);
}
