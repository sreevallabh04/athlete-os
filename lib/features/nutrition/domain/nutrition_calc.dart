import 'food_models.dart';
import 'nutrients.dart';

/// Minimal view of a logged entry used by the calculations below. The data
/// layer adapts Drift rows to this so the math stays pure.
class LogLine {
  const LogLine({
    required this.localDate,
    required this.mealType,
    required this.nutrients,
    this.verification = Verifications.userEntered,
    this.deleted = false,
    this.name = '',
    this.foodId,
  });

  final String localDate;
  final String mealType;
  final Nutrients nutrients;
  final String verification;
  final bool deleted;
  final String name;
  final String? foodId;
}

/// Daily targets from the profile. A target <= 0 means "no target".
class NutritionTargets {
  const NutritionTargets({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.fiber,
  });

  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final double? fiber;
}

/// Totals for one day.
class DayTotals {
  const DayTotals({
    required this.total,
    required this.byMeal,
    required this.entryCount,
    required this.estimateCount,
  });

  final Nutrients total;
  final Map<MealType, Nutrients> byMeal;
  final int entryCount;

  /// Entries whose values are estimates (AI / quick add).
  final int estimateCount;

  bool get isEmpty => entryCount == 0;

  /// Sums [lines], ignoring soft-deleted rows.
  factory DayTotals.fromLines(Iterable<LogLine> lines) {
    var total = Nutrients.zero;
    final byMeal = {for (final m in MealType.values) m: Nutrients.zero};
    var count = 0;
    var estimates = 0;
    for (final l in lines) {
      if (l.deleted) continue;
      count++;
      if (Verifications.isEstimate(l.verification)) estimates++;
      total = total + l.nutrients;
      final m = MealType.fromKey(l.mealType);
      byMeal[m] = byMeal[m]! + l.nutrients;
    }
    return DayTotals(
      total: total,
      byMeal: byMeal,
      entryCount: count,
      estimateCount: estimates,
    );
  }
}

/// Remaining amount vs a target. Never clamped: a negative [value] means the
/// target was exceeded ("over by").
class Remaining {
  const Remaining({required this.consumed, required this.target});

  final double consumed;

  /// `null` when no target is set (target <= 0 or missing).
  final double? target;

  bool get hasTarget => target != null && target! > 0;

  /// target − consumed; null without a target.
  double? get value => hasTarget ? target! - consumed : null;
  bool get isOver => hasTarget && value! < 0;
  double get overBy => isOver ? -value! : 0;

  /// For ring/bar visuals only: 0..1.
  double get visualProgress => ringProgress(consumed, target);

  /// Unclamped ratio consumed/target (e.g. 1.2 = 120%); 0 without target.
  double get ratio => hasTarget ? consumed / target! : 0;

  /// "1,234 left" / "over by 56" style label (no units).
  String label(String Function(double) fmt) {
    if (!hasTarget) return 'No target set';
    return isOver ? 'over by ${fmt(overBy)}' : '${fmt(value!)} left';
  }
}

/// Clamp helper for ring visuals only. Never use for stored values.
double ringProgress(double consumed, double? target) {
  if (target == null || target <= 0 || !consumed.isFinite) return 0;
  final p = consumed / target;
  if (p < 0) return 0;
  return p > 1 ? 1 : p;
}

class RemainingSummary {
  const RemainingSummary({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.fiber,
  });

  final Remaining calories;
  final Remaining protein;
  final Remaining carbs;
  final Remaining fat;
  final Remaining fiber;

  factory RemainingSummary.compute(Nutrients consumed, NutritionTargets t) {
    double? tgt(double? v) => v != null && v > 0 ? v : null;
    return RemainingSummary(
      calories: Remaining(consumed: consumed.calories, target: tgt(t.calories)),
      protein: Remaining(consumed: consumed.protein, target: tgt(t.protein)),
      carbs: Remaining(consumed: consumed.carbs, target: tgt(t.carbs)),
      fat: Remaining(consumed: consumed.fat, target: tgt(t.fat)),
      fiber: Remaining(consumed: consumed.fiber ?? 0, target: tgt(t.fiber)),
    );
  }
}

/// Share of energy from each macro, using Atwater factors 4/4/9.
/// Percentages are of macro-derived energy (not the label kcal), so they
/// always describe the split even when label kcal differs slightly.
class MacroSplit {
  const MacroSplit({
    required this.proteinKcal,
    required this.carbsKcal,
    required this.fatKcal,
  });

  factory MacroSplit.of(Nutrients n) => MacroSplit(
    proteinKcal: n.protein * 4,
    carbsKcal: n.carbs * 4,
    fatKcal: n.fat * 9,
  );

  final double proteinKcal;
  final double carbsKcal;
  final double fatKcal;

  double get totalKcal => proteinKcal + carbsKcal + fatKcal;
  bool get isEmpty => totalKcal <= 0;

  double get proteinPct => isEmpty ? 0 : proteinKcal / totalKcal * 100;
  double get carbsPct => isEmpty ? 0 : carbsKcal / totalKcal * 100;
  double get fatPct => isEmpty ? 0 : fatKcal / totalKcal * 100;

  /// Integer percentages (protein, carbs, fat) that sum to exactly 100 using
  /// the largest-remainder method; all zero when there is no energy.
  (int, int, int) roundedPercents() {
    if (isEmpty) return (0, 0, 0);
    final raw = [proteinPct, carbsPct, fatPct];
    final floors = raw.map((v) => v.floor()).toList();
    var remainder = 100 - floors.fold<int>(0, (a, b) => a + b);
    final order = [0, 1, 2]
      ..sort((a, b) {
        final c = (raw[b] - floors[b]).compareTo(raw[a] - floors[a]);
        return c != 0 ? c : a.compareTo(b);
      });
    for (final i in order) {
      if (remainder <= 0) break;
      floors[i]++;
      remainder--;
    }
    return (floors[0], floors[1], floors[2]);
  }
}

/// Target adherence rules.
abstract final class Adherence {
  /// Protein: met when within 10% below target or anything above it.
  static bool protein(double consumed, double target) {
    if (target <= 0) return false;
    return consumed >= target * 0.9;
  }

  /// Calories: met when within ±10% of target.
  static bool calories(double consumed, double target) {
    if (target <= 0) return false;
    return consumed >= target * 0.9 && consumed <= target * 1.1;
  }
}

/// Totals for one calendar day in a range.
class DaySummary {
  const DaySummary({
    required this.localDate,
    required this.total,
    required this.entryCount,
  });
  final String localDate;
  final Nutrients total;
  final int entryCount;
  bool get hasLogs => entryCount > 0;
}

/// Groups [lines] into per-day summaries for every date in [dates] (days with
/// no entries get zero totals and `entryCount == 0`).
List<DaySummary> summarizeDays(List<String> dates, Iterable<LogLine> lines) {
  final byDate = <String, List<LogLine>>{};
  for (final l in lines) {
    if (l.deleted) continue;
    (byDate[l.localDate] ??= []).add(l);
  }
  return [
    for (final d in dates)
      () {
        final t = DayTotals.fromLines(byDate[d] ?? const []);
        return DaySummary(
          localDate: d,
          total: t.total,
          entryCount: t.entryCount,
        );
      }(),
  ];
}

/// Averages over a period, counting ONLY days that have at least one log
/// (an unlogged day is "unknown", not "zero calories").
class PeriodAverages {
  const PeriodAverages({
    required this.average,
    required this.loggedDays,
    required this.totalDays,
    required this.proteinAdherentDays,
    required this.calorieAdherentDays,
  });

  final Nutrients average;
  final int loggedDays;
  final int totalDays;
  final int proteinAdherentDays;
  final int calorieAdherentDays;

  bool get hasData => loggedDays > 0;

  /// Percentage (0–100) of logged days meeting the protein target.
  double get proteinAdherencePct =>
      loggedDays == 0 ? 0 : proteinAdherentDays / loggedDays * 100;
  double get calorieAdherencePct =>
      loggedDays == 0 ? 0 : calorieAdherentDays / loggedDays * 100;

  factory PeriodAverages.compute(
    List<DaySummary> days,
    NutritionTargets targets,
  ) {
    final logged = days.where((d) => d.hasLogs).toList();
    var sum = Nutrients.zero;
    var pDays = 0;
    var cDays = 0;
    var fiberDays = 0;
    for (final d in logged) {
      sum = sum + d.total;
      if (d.total.fiber != null) fiberDays++;
      if (Adherence.protein(d.total.protein, targets.protein)) pDays++;
      if (Adherence.calories(d.total.calories, targets.calories)) cDays++;
    }
    final n = logged.length;
    final avg = n == 0
        ? Nutrients.zero
        : Nutrients(
            calories: sum.calories / n,
            protein: sum.protein / n,
            carbs: sum.carbs / n,
            fat: sum.fat / n,
            fiber: fiberDays == 0 ? null : sum.fiber! / fiberDays,
          );
    return PeriodAverages(
      average: avg,
      loggedDays: n,
      totalDays: days.length,
      proteinAdherentDays: pDays,
      calorieAdherentDays: cDays,
    );
  }
}

/// Averages per ISO week (Monday start) for [days], keyed by the Monday date
/// and ordered oldest first. [weekStartOf] maps a date key to its week start
/// (pass `LocalDates.weekStart`). Each week averages its logged days only.
Map<String, PeriodAverages> weeklyAverages(
  List<DaySummary> days,
  NutritionTargets targets,
  String Function(String date) weekStartOf,
) {
  final groups = <String, List<DaySummary>>{};
  for (final d in days) {
    (groups[weekStartOf(d.localDate)] ??= []).add(d);
  }
  final keys = groups.keys.toList()..sort();
  return {for (final k in keys) k: PeriodAverages.compute(groups[k]!, targets)};
}

/// Grams of protein per 100 kcal; null when there is no energy.
double? proteinPer100Kcal(Nutrients n) {
  if (n.calories <= 0) return null;
  return n.protein / n.calories * 100;
}

/// A named food/meal with its total nutrients and how often it was eaten.
class NamedNutrients {
  const NamedNutrients({
    required this.name,
    required this.nutrients,
    this.timesLogged = 1,
  });
  final String name;
  final Nutrients nutrients;
  final int timesLogged;

  double? get proteinEfficiency => proteinPer100Kcal(nutrients);
}

/// Ranks items by protein efficiency (desc). Items without energy are
/// excluded. Ties break by name for determinism.
List<NamedNutrients> rankByProteinEfficiency(Iterable<NamedNutrients> items) {
  final list = items.where((i) => i.proteinEfficiency != null).toList()
    ..sort((a, b) {
      final c = b.proteinEfficiency!.compareTo(a.proteinEfficiency!);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
  return list;
}

/// "Usual" foods: things logged at least [minTimes] times in [lines], grouped
/// by food id (or lower-cased name when there is no food id). Nutrients are
/// summed across all logs so efficiency reflects real portions.
List<NamedNutrients> usualFoods(Iterable<LogLine> lines, {int minTimes = 2}) {
  final groups = <String, List<LogLine>>{};
  for (final l in lines) {
    if (l.deleted) continue;
    final key = l.foodId ?? 'name:${l.name.trim().toLowerCase()}';
    (groups[key] ??= []).add(l);
  }
  final out = <NamedNutrients>[];
  for (final g in groups.values) {
    if (g.length < minTimes) continue;
    var sum = Nutrients.zero;
    for (final l in g) {
      sum = sum + l.nutrients;
    }
    out.add(
      NamedNutrients(name: g.first.name, nutrients: sum, timesLogged: g.length),
    );
  }
  return out;
}

/// Water progress for a day.
class HydrationSummary {
  const HydrationSummary({required this.totalMl, required this.goalMl});

  /// Sums [amountsMl] (callers pass non-deleted rows only).
  factory HydrationSummary.fromAmounts(Iterable<int> amountsMl, int goalMl) =>
      HydrationSummary(
        totalMl: amountsMl.fold(0, (a, b) => a + b),
        goalMl: goalMl,
      );

  final int totalMl;
  final int goalMl;

  bool get hasGoal => goalMl > 0;

  /// goal − total; negative when the goal is exceeded. 0 without a goal.
  int get remainingMl => hasGoal ? goalMl - totalMl : 0;
  bool get goalReached => hasGoal && totalMl >= goalMl;
  double get visualProgress =>
      ringProgress(totalMl.toDouble(), goalMl.toDouble());
}

/// Recipe nutrition per serving: sum of ingredient snapshots / yield.
Nutrients recipePerServing(Iterable<Nutrients> ingredients, double servings) {
  if (!servings.isFinite || servings <= 0) {
    throw ArgumentError.value(servings, 'servings', 'must be > 0');
  }
  var sum = Nutrients.zero;
  for (final i in ingredients) {
    sum = sum + i;
  }
  return sum.scale(1 / servings);
}
