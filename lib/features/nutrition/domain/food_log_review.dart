/// Deterministic post-processing for AI bulk food logs. Pure and unit
/// tested: whatever the model returns, the numbers the user reviews (and
/// that get written) pass through these rules.
library;

import 'dart:math' as math;

import 'food_log_parser.dart';
import 'food_models.dart';
import 'nutrients.dart';
import 'nutrition_calc.dart';

/// Hard caps for one item (a whole portion). Values above are clamped and
/// the item is flagged.
abstract final class FoodLogLimits {
  static const grams = 3000.0;
  static const kcal = 5000.0;
  static const protein = 300.0;
  static const carbs = 600.0;
  static const fat = 300.0;
  static const fiber = 100.0;
  static const nameChars = 80;
  static const quantityChars = 60;
  static const noteChars = 160;

  /// kcal vs 4/4/9 macros: relative tolerance and an absolute floor so tiny
  /// items (black coffee, 2 kcal) are not "corrected" over rounding noise.
  static const kcalTolerance = 0.20;
  static const kcalAbsoluteSlack = 25.0;

  /// Items below this confidence get a "check me" hint in the UI.
  static const lowConfidence = 0.5;
}

/// Why an item's values were changed by [sanitizeFoodLog].
enum ReviewFlag {
  /// kcal disagreed with the macros by > 20 % and was recomputed (4/4/9).
  kcalRecomputed,

  /// A value was negative/absurd and was clamped.
  clamped,

  /// The parser gave no meal; one was assigned from the time of day.
  mealDefaulted,

  /// The user edited the item.
  edited,
}

/// One reviewable item. Immutable; edits produce a copy.
class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.name,
    required this.nutrients,
    required this.mealType,
    this.quantity,
    this.grams,
    this.confidence,
    this.note,
    this.flags = const {},
  });

  final String id;
  final String name;
  final String? quantity;
  final double? grams;
  final Nutrients nutrients;
  final MealType mealType;
  final double? confidence;
  final String? note;
  final Set<ReviewFlag> flags;

  bool get isLowConfidence =>
      confidence != null && confidence! < FoodLogLimits.lowConfidence;

  ReviewItem copyWith({
    String? name,
    String? Function()? quantity,
    double? Function()? grams,
    Nutrients? nutrients,
    MealType? mealType,
    Set<ReviewFlag>? flags,
  }) => ReviewItem(
    id: id,
    name: name ?? this.name,
    quantity: quantity != null ? quantity() : this.quantity,
    grams: grams != null ? grams() : this.grams,
    nutrients: nutrients ?? this.nutrients,
    mealType: mealType ?? this.mealType,
    confidence: confidence,
    note: note,
    flags: flags ?? this.flags,
  );

  /// Rescales nutrients proportionally to [newGrams]. Without a known
  /// weight the item is returned unchanged.
  ReviewItem scaledToGrams(double newGrams) {
    final g = grams;
    if (g == null || g <= 0 || !newGrams.isFinite || newGrams <= 0) {
      return this;
    }
    final clamped = newGrams.clamp(1.0, FoodLogLimits.grams).toDouble();
    return copyWith(
      grams: () => clamped,
      nutrients: nutrients.scale(clamped / g).rounded(),
      flags: {...flags, ReviewFlag.edited},
    );
  }

  /// Note stored on the log entry: portion + assumptions.
  String? get logNote {
    final parts = [
      if (quantity != null && quantity!.isNotEmpty) quantity!,
      if (note != null && note!.isNotEmpty) note!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class SanitizedFoodLog {
  const SanitizedFoodLog({
    required this.items,
    required this.unparsed,
    required this.duplicatesRemoved,
  });
  final List<ReviewItem> items;
  final List<String> unparsed;
  final int duplicatesRemoved;

  int get adjustedCount => items
      .where(
        (i) =>
            i.flags.contains(ReviewFlag.kcalRecomputed) ||
            i.flags.contains(ReviewFlag.clamped),
      )
      .length;
}

/// kcal from macros with Atwater factors (fiber ignored).
double macroKcal(Nutrients n) => n.protein * 4 + n.carbs * 4 + n.fat * 9;

/// True when [kcal] and the macros disagree beyond the tolerance.
bool kcalInconsistent(double kcal, Nutrients n) {
  final m = macroKcal(n);
  if (m <= 0) return false;
  final diff = (kcal - m).abs();
  if (diff <= FoodLogLimits.kcalAbsoluteSlack) return false;
  return diff / math.max(kcal, m) > FoodLogLimits.kcalTolerance;
}

String? _cleanText(String? s, int max) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length > max ? '${t.substring(0, max - 1)}…' : t;
}

/// Validates and sanitises parser output:
/// * drops nameless items; trims and caps text;
/// * clamps negatives / non-finite values to 0 and absurd values to
///   [FoodLogLimits] (flag [ReviewFlag.clamped]);
/// * recomputes kcal from macros when they disagree by > 20 %
///   (flag [ReviewFlag.kcalRecomputed]);
/// * assigns `MealType.forTime(now)` when the meal is unknown
///   (flag [ReviewFlag.mealDefaulted]);
/// * removes exact duplicates (same name, portion, grams, kcal and meal).
SanitizedFoodLog sanitizeFoodLog(
  List<ParsedFoodItem> raw, {
  required DateTime now,
  List<String> unparsed = const [],
}) {
  final defaultMeal = MealType.forTime(now);
  final seen = <String>{};
  final out = <ReviewItem>[];
  var dupes = 0;
  for (final p in raw) {
    final name = _cleanText(p.name, FoodLogLimits.nameChars);
    if (name == null) continue;
    final flags = <ReviewFlag>{};
    double clean(double? v, double max) {
      if (v == null || !v.isFinite || v < 0) {
        if (v != null && v < 0) flags.add(ReviewFlag.clamped);
        return 0;
      }
      if (v > max) {
        flags.add(ReviewFlag.clamped);
        return max;
      }
      return v;
    }

    final n0 = p.nutrients;
    final protein = clean(n0.protein, FoodLogLimits.protein);
    final carbs = clean(n0.carbs, FoodLogLimits.carbs);
    final fat = clean(n0.fat, FoodLogLimits.fat);
    final fiber = n0.fiber == null
        ? null
        : clean(n0.fiber, FoodLogLimits.fiber);
    var kcal = clean(n0.calories, FoodLogLimits.kcal);
    final macros = Nutrients(
      calories: kcal,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );
    if (kcalInconsistent(kcal, macros) ||
        (kcal == 0 && macroKcal(macros) > 0)) {
      kcal = math.min(macroKcal(macros), FoodLogLimits.kcal);
      flags.add(ReviewFlag.kcalRecomputed);
    }
    double? grams;
    if (p.grams != null && p.grams!.isFinite && p.grams! > 0) {
      grams = p.grams! > FoodLogLimits.grams ? FoodLogLimits.grams : p.grams!;
      if (p.grams! > FoodLogLimits.grams) flags.add(ReviewFlag.clamped);
    }
    final meal = p.mealType ?? defaultMeal;
    if (p.mealType == null) flags.add(ReviewFlag.mealDefaulted);
    final conf = p.confidence;
    final quantity = _cleanText(
      p.quantityDescription,
      FoodLogLimits.quantityChars,
    );
    final n = Nutrients(
      calories: kcal,
      protein: protein,
      carbs: carbs,
      fat: fat,
      fiber: fiber,
    ).rounded();
    final key = [
      name.toLowerCase(),
      quantity?.toLowerCase() ?? '',
      grams?.round() ?? '',
      n.calories.round(),
      meal.key,
    ].join('|');
    if (!seen.add(key)) {
      dupes++;
      continue;
    }
    out.add(
      ReviewItem(
        id: 'i${out.length}',
        name: name,
        quantity: quantity,
        grams: grams == null ? null : round1(grams),
        nutrients: n,
        mealType: meal,
        confidence: conf == null || !conf.isFinite
            ? null
            : conf.clamp(0.0, 1.0).toDouble(),
        note: _cleanText(p.note, FoodLogLimits.noteChars),
        flags: flags,
      ),
    );
  }
  final frags = <String>[];
  for (final u in unparsed) {
    final t = _cleanText(u, 120);
    if (t != null && !frags.contains(t)) frags.add(t);
    if (frags.length >= 12) break;
  }
  return SanitizedFoodLog(
    items: out,
    unparsed: frags,
    duplicatesRemoved: dupes,
  );
}

/// Totals for the reviewed items.
class FoodLogSummary {
  const FoodLogSummary({
    required this.total,
    required this.byMeal,
    required this.split,
    required this.count,
    required this.lowConfidenceCount,
  });

  factory FoodLogSummary.of(Iterable<ReviewItem> items) {
    var total = Nutrients.zero;
    final byMeal = <MealType, Nutrients>{};
    var count = 0;
    var low = 0;
    for (final i in items) {
      count++;
      if (i.isLowConfidence) low++;
      total = total + i.nutrients;
      byMeal[i.mealType] = (byMeal[i.mealType] ?? Nutrients.zero) + i.nutrients;
    }
    return FoodLogSummary(
      total: total.rounded(),
      byMeal: byMeal,
      split: MacroSplit.of(total),
      count: count,
      lowConfidenceCount: low,
    );
  }

  final Nutrients total;

  /// Only meals that have items, in [MealType] order when iterated via
  /// [meals].
  final Map<MealType, Nutrients> byMeal;
  final MacroSplit split;
  final int count;
  final int lowConfidenceCount;

  List<MealType> get meals => [
    for (final m in MealType.values)
      if (byMeal.containsKey(m)) m,
  ];
}

/// Before → after for one nutrient vs its daily target.
class ImpactLine {
  const ImpactLine({
    required this.before,
    required this.added,
    required this.target,
  });

  final double before;
  final double added;

  /// Null when no target is set.
  final double? target;

  double get after => before + added;
  Remaining get remainingBefore => Remaining(consumed: before, target: target);
  Remaining get remainingAfter => Remaining(consumed: after, target: target);
  bool get hasTarget => remainingAfter.hasTarget;
  bool get overAfter => remainingAfter.isOver;

  /// True when this paste is what pushes the day over target.
  bool get crossesTarget => !remainingBefore.isOver && overAfter;

  /// 0..1 shares of the target for bar visuals (unclamped beyond 1 is
  /// reported by [overAfter]).
  double get beforeFraction => hasTarget ? before / target! : 0;
  double get afterFraction => hasTarget ? after / target! : 0;
}

/// Effect of logging the reviewed items on the day's totals.
class FoodLogImpact {
  const FoodLogImpact({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  /// [existing]: what is already logged on that day; [added]: the paste.
  factory FoodLogImpact.compute({
    required Nutrients existing,
    required Nutrients added,
    required NutritionTargets targets,
  }) {
    double? t(double v) => v > 0 ? v : null;
    return FoodLogImpact(
      calories: ImpactLine(
        before: existing.calories,
        added: added.calories,
        target: t(targets.calories),
      ),
      protein: ImpactLine(
        before: existing.protein,
        added: added.protein,
        target: t(targets.protein),
      ),
      carbs: ImpactLine(
        before: existing.carbs,
        added: added.carbs,
        target: t(targets.carbs),
      ),
      fat: ImpactLine(
        before: existing.fat,
        added: added.fat,
        target: t(targets.fat),
      ),
    );
  }

  final ImpactLine calories;
  final ImpactLine protein;
  final ImpactLine carbs;
  final ImpactLine fat;
}
