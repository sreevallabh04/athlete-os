/// Pure nutrient math. No Flutter, no Drift: everything here is deterministic
/// and unit tested so totals shown in the UI are never improvised.
library;

/// Energy + macronutrients for some amount of food.
///
/// [fiber] is nullable because many sources do not report it; `null` means
/// "unknown", which is different from `0`.
class Nutrients {
  const Nutrients({
    required this.calories,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    this.fiber,
  });

  static const zero = Nutrients(calories: 0);

  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final double? fiber;

  /// Sum. Fiber stays `null` only when both sides are unknown.
  Nutrients operator +(Nutrients o) => Nutrients(
    calories: calories + o.calories,
    protein: protein + o.protein,
    carbs: carbs + o.carbs,
    fat: fat + o.fat,
    fiber: fiber == null && o.fiber == null
        ? null
        : (fiber ?? 0) + (o.fiber ?? 0),
  );

  Nutrients scale(double factor) => Nutrients(
    calories: calories * factor,
    protein: protein * factor,
    carbs: carbs * factor,
    fat: fat * factor,
    fiber: fiber == null ? null : fiber! * factor,
  );

  /// Display/storage rounding: kcal to 1 decimal, macros to 1 decimal.
  Nutrients rounded() => Nutrients(
    calories: round1(calories),
    protein: round1(protein),
    carbs: round1(carbs),
    fat: round1(fat),
    fiber: fiber == null ? null : round1(fiber!),
  );

  Map<String, Object?> toJson() => {
    'calories': calories,
    'protein_g': protein,
    'carbs_g': carbs,
    'fat_g': fat,
    if (fiber != null) 'fiber_g': fiber,
  };

  @override
  bool operator ==(Object other) =>
      other is Nutrients &&
      other.calories == calories &&
      other.protein == protein &&
      other.carbs == carbs &&
      other.fat == fat &&
      other.fiber == fiber;

  @override
  int get hashCode => Object.hash(calories, protein, carbs, fat, fiber);

  @override
  String toString() =>
      'Nutrients(kcal: $calories, P: $protein, C: $carbs, F: $fat, '
      'fiber: $fiber)';
}

/// Rounds half away from zero to one decimal place.
double round1(double v) {
  if (!v.isFinite) return 0;
  return (v * 10).roundToDouble() / 10;
}

/// How a food's nutrients are expressed: values are for ONE serving of
/// `servingSize servingUnit`. When [gramsPerServing] is known (always for
/// per-100 g foods) the food can also be measured in grams (or ml for liquids,
/// see [baseUnit]).
class ServingBasis {
  const ServingBasis({
    required this.perServing,
    this.servingSize = 100,
    this.servingUnit = 'g',
    this.gramsPerServing,
  });

  /// A food described per 100 g (USDA, Open Food Facts `_100g` values).
  factory ServingBasis.per100g(Nutrients per100g, {String unit = 'g'}) =>
      ServingBasis(
        perServing: per100g,
        servingSize: 100,
        servingUnit: unit,
        gramsPerServing: 100,
      );

  final Nutrients perServing;
  final double servingSize;
  final String servingUnit;
  final double? gramsPerServing;

  bool get supportsGrams => gramsPerServing != null && gramsPerServing! > 0;

  /// Unit used for weight/volume entry: 'ml' for liquids, otherwise 'g'.
  String get baseUnit => servingUnit.toLowerCase() == 'ml' ? 'ml' : 'g';

  /// Human label for one serving, e.g. "100 g", "1 piece (40 g)".
  String get servingLabel {
    final size = _trim(servingSize);
    final unit = servingUnit;
    final grams = gramsPerServing;
    final base = '$size $unit';
    if (grams != null &&
        grams > 0 &&
        unit.toLowerCase() != 'g' &&
        unit.toLowerCase() != 'ml') {
      return '$base (${_trim(grams)} $baseUnit)';
    }
    return base;
  }
}

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : round1(v).toString();

/// Nutrients for [servings] servings.
Nutrients nutrientsForServings(ServingBasis basis, double servings) {
  if (!servings.isFinite || servings < 0) {
    throw ArgumentError.value(servings, 'servings', 'must be >= 0');
  }
  return basis.perServing.scale(servings);
}

/// Nutrients for [grams] grams (or ml), via `gramsPerServing`.
Nutrients nutrientsForGrams(ServingBasis basis, double grams) {
  if (!basis.supportsGrams) {
    throw StateError('Food has no grams-per-serving; use servings instead.');
  }
  if (!grams.isFinite || grams < 0) {
    throw ArgumentError.value(grams, 'grams', 'must be >= 0');
  }
  return basis.perServing.scale(grams / basis.gramsPerServing!);
}

/// Converts per-100 g values to a serving of [grams] grams.
Nutrients per100gToAmount(Nutrients per100g, double grams) =>
    per100g.scale(grams / 100);

enum AmountMode { servings, grams }

/// A user-entered amount, either a number of servings or a weight.
class Amount {
  const Amount.servings(this.value) : mode = AmountMode.servings;
  const Amount.grams(this.value) : mode = AmountMode.grams;

  final AmountMode mode;
  final double value;

  bool get isValid => value.isFinite && value > 0;
}

/// Fully resolved amount: servings + grams (when known) + nutrient snapshot.
class ResolvedAmount {
  const ResolvedAmount({
    required this.servings,
    required this.grams,
    required this.nutrients,
  });
  final double servings;
  final double? grams;
  final Nutrients nutrients;
}

ResolvedAmount resolveAmount(ServingBasis basis, Amount amount) {
  switch (amount.mode) {
    case AmountMode.servings:
      return ResolvedAmount(
        servings: amount.value,
        grams: basis.supportsGrams
            ? amount.value * basis.gramsPerServing!
            : null,
        nutrients: nutrientsForServings(basis, amount.value),
      );
    case AmountMode.grams:
      final n = nutrientsForGrams(basis, amount.value);
      return ResolvedAmount(
        servings: amount.value / basis.gramsPerServing!,
        grams: amount.value,
        nutrients: n,
      );
  }
}
