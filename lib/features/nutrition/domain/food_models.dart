import 'nutrients.dart';

/// Meal slots used by the food log.
enum MealType {
  breakfast('breakfast', 'Breakfast'),
  lunch('lunch', 'Lunch'),
  dinner('dinner', 'Dinner'),
  snack('snack', 'Snacks');

  const MealType(this.key, this.label);
  final String key;
  final String label;

  static MealType fromKey(String? key) => MealType.values.firstWhere(
    (m) => m.key == key,
    orElse: () => MealType.snack,
  );

  static MealType? tryParse(String? key) {
    for (final m in MealType.values) {
      if (m.key == key) return m;
    }
    return null;
  }

  /// Default meal for the local time of day.
  /// 04:00–10:59 breakfast, 11:00–15:59 lunch, 16:00–17:59 snack,
  /// 18:00–21:59 dinner, otherwise snack.
  static MealType forTime(DateTime localTime) {
    final h = localTime.hour;
    if (h >= 4 && h < 11) return MealType.breakfast;
    if (h >= 11 && h < 16) return MealType.lunch;
    if (h >= 18 && h < 22) return MealType.dinner;
    return MealType.snack;
  }
}

/// Where a food / log entry came from (stored in `source`).
abstract final class FoodSources {
  static const openFoodFacts = 'openfoodfacts';
  static const usda = 'usda';
  static const custom = 'custom';
  static const aiEstimate = 'ai_estimate';
  static const quickAdd = 'quick_add';
  static const recipe = 'recipe';

  static String label(String source) => switch (source) {
    openFoodFacts => 'Open Food Facts',
    usda => 'USDA FoodData Central',
    custom => 'My food',
    aiEstimate => 'AI estimate',
    quickAdd => 'Quick add',
    recipe => 'Recipe',
    _ => source,
  };
}

/// How trustworthy the nutrient values are (stored in `verification`).
abstract final class Verifications {
  /// Barcode label data from Open Food Facts with complete nutriments.
  static const verifiedLabel = 'verified_label';

  /// Generic database values (USDA / OFF text search).
  static const database = 'database';

  /// Typed in by the user.
  static const userEntered = 'user_entered';

  /// AI or quick-add estimate. Always shown with an ESTIMATE badge.
  static const estimate = 'estimate';

  static bool isEstimate(String v) => v == estimate;

  static String label(String v) => switch (v) {
    verifiedLabel => 'Label (barcode)',
    database => 'Database',
    userEntered => 'Entered by you',
    estimate => 'Estimate',
    _ => v,
  };

  /// When combining items (recipes, saved meals) the weakest level wins.
  static String weakest(Iterable<String> values) {
    const order = [estimate, userEntered, database, verifiedLabel];
    var worst = verifiedLabel;
    var any = false;
    for (final v in values) {
      any = true;
      final i = order.indexOf(v);
      if (i >= 0 && i < order.indexOf(worst)) worst = v;
    }
    return any ? worst : userEntered;
  }
}

/// Serving units offered in the custom food form.
const servingUnits = ['g', 'ml', 'serving', 'piece', 'cup', 'slice', 'tbsp'];

/// Input for creating or updating a local food. Nutrients are per serving.
class FoodDraft {
  const FoodDraft({
    required this.name,
    required this.basis,
    required this.source,
    required this.verification,
    this.brand,
    this.barcode,
    this.sourceId,
    this.rawJson,
    this.isFavorite = false,
  });

  final String name;
  final String? brand;
  final String? barcode;
  final ServingBasis basis;
  final String source;
  final String? sourceId;
  final String verification;
  final String? rawJson;
  final bool isFavorite;
}

/// Field-level validation for the custom food form. Returns an empty map when
/// valid. Keys: name, servingSize, gramsPerServing, calories, protein, carbs,
/// fat, fiber, barcode.
Map<String, String> validateFoodInput({
  required String name,
  required String servingSize,
  required String servingUnit,
  required String gramsPerServing,
  required String calories,
  required String protein,
  required String carbs,
  required String fat,
  required String fiber,
  String barcode = '',
}) {
  final errors = <String, String>{};
  if (name.trim().isEmpty) errors['name'] = 'Enter a name';
  if (name.trim().length > 120) errors['name'] = 'Name is too long';

  double? parse(String key, String raw, {bool required = true, double? max}) {
    final t = raw.trim().replaceAll(',', '.');
    if (t.isEmpty) {
      if (required) errors[key] = 'Required';
      return null;
    }
    final v = double.tryParse(t);
    if (v == null || !v.isFinite) {
      errors[key] = 'Enter a number';
      return null;
    }
    if (v < 0) {
      errors[key] = 'Must be 0 or more';
      return null;
    }
    if (max != null && v > max) {
      errors[key] = 'Must be at most ${max.toInt()}';
      return null;
    }
    return v;
  }

  final size = parse('servingSize', servingSize, max: 5000);
  if (size != null && size <= 0) errors['servingSize'] = 'Must be more than 0';
  // Optional for non-weight units (piece, cup...); ignored for g/ml where it
  // equals the serving size.
  final gps = parse('gramsPerServing', gramsPerServing, required: false);
  if (gps != null && gps <= 0) {
    errors['gramsPerServing'] = 'Must be more than 0';
  }
  final kcal = parse('calories', calories, max: 10000);
  final p = parse('protein', protein, max: 1000);
  final c = parse('carbs', carbs, max: 1000);
  final f = parse('fat', fat, max: 1000);
  parse('fiber', fiber, required: false, max: 1000);

  // Sanity: macro energy should not wildly exceed stated calories.
  if (kcal != null && p != null && c != null && f != null) {
    final macroKcal = p * 4 + c * 4 + f * 9;
    if (macroKcal > kcal * 1.5 + 20) {
      errors['calories'] =
          'Calories look too low for these macros '
          '(~${macroKcal.round()} kcal from P/C/F)';
    }
  }
  final code = barcode.trim();
  if (code.isNotEmpty && !RegExp(r'^\d{6,14}$').hasMatch(code)) {
    errors['barcode'] = 'Barcodes are 6–14 digits';
  }
  return errors;
}

/// A food result from a remote database (Open Food Facts or USDA) before it is
/// saved locally. Missing nutrients stay `null` — nothing is invented.
class FoodCandidate {
  const FoodCandidate({
    required this.name,
    required this.source,
    required this.sourceId,
    this.brand,
    this.barcode,
    this.kcal100g,
    this.protein100g,
    this.carbs100g,
    this.fat100g,
    this.fiber100g,
    this.kcalServing,
    this.proteinServing,
    this.carbsServing,
    this.fatServing,
    this.fiberServing,
    this.servingQuantity,
    this.servingUnit = 'g',
    this.servingLabel,
    this.energyFromKj = false,
    this.raw = const {},
  });

  final String name;
  final String? brand;
  final String? barcode;
  final String source;
  final String sourceId;

  final double? kcal100g;
  final double? protein100g;
  final double? carbs100g;
  final double? fat100g;
  final double? fiber100g;

  final double? kcalServing;
  final double? proteinServing;
  final double? carbsServing;
  final double? fatServing;
  final double? fiberServing;

  /// Grams (or ml, see [servingUnit]) in one labelled serving.
  final double? servingQuantity;

  /// 'g' or 'ml'.
  final String servingUnit;

  /// Free-text serving description from the label, e.g. "1 bar (40 g)".
  final String? servingLabel;

  /// True if kcal was converted from kJ (1 kcal = 4.184 kJ).
  final bool energyFromKj;

  /// Original provider values (subset), preserved in `rawJson`.
  final Map<String, Object?> raw;

  bool get hasPer100g =>
      kcal100g != null &&
      protein100g != null &&
      carbs100g != null &&
      fat100g != null;

  bool get hasPerServing =>
      kcalServing != null &&
      proteinServing != null &&
      carbsServing != null &&
      fatServing != null;

  /// Complete = energy + protein + carbs + fat known on some basis.
  bool get isComplete => hasPer100g || hasPerServing;

  /// Names of core nutrients that are missing on every basis.
  List<String> get missingNutrients => [
    if (kcal100g == null && kcalServing == null) 'calories',
    if (protein100g == null && proteinServing == null) 'protein',
    if (carbs100g == null && carbsServing == null) 'carbs',
    if (fat100g == null && fatServing == null) 'fat',
  ];

  /// The serving basis to store locally, or null when incomplete.
  ///
  /// Prefers per-100 g values scaled to the labelled serving (if known) so
  /// both "servings" and "grams" entry work; falls back to per-serving values.
  ServingBasis? toBasis() {
    final sq = servingQuantity;
    if (hasPer100g) {
      final per100 = Nutrients(
        calories: kcal100g!,
        protein: protein100g!,
        carbs: carbs100g!,
        fat: fat100g!,
        fiber: fiber100g,
      );
      if (sq != null && sq > 0) {
        return ServingBasis(
          perServing: per100gToAmount(per100, sq),
          servingSize: sq,
          servingUnit: servingUnit,
          gramsPerServing: sq,
        );
      }
      return ServingBasis.per100g(per100, unit: servingUnit);
    }
    if (hasPerServing) {
      return ServingBasis(
        perServing: Nutrients(
          calories: kcalServing!,
          protein: proteinServing!,
          carbs: carbsServing!,
          fat: fatServing!,
          fiber: fiberServing,
        ),
        servingSize: sq != null && sq > 0 ? sq : 1,
        servingUnit: sq != null && sq > 0 ? servingUnit : 'serving',
        gramsPerServing: sq != null && sq > 0 ? sq : null,
      );
    }
    return null;
  }
}
