import '../../../data/db/database.dart';
import '../domain/csv_export.dart';
import '../domain/nl_parser.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';

/// Adapters between Drift rows and the pure domain types.
extension FoodX on Food {
  Nutrients get perServing => Nutrients(
    calories: calories,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
    fiber: fiberG,
  );

  ServingBasis get basis => ServingBasis(
    perServing: perServing,
    servingSize: servingSize,
    servingUnit: servingUnit,
    gramsPerServing: _effectiveGrams,
  );

  /// For g/ml-defined foods the grams per serving equals the serving size
  /// even if the column was left empty.
  double? get _effectiveGrams {
    if (gramsPerServing != null && gramsPerServing! > 0) {
      return gramsPerServing;
    }
    final u = servingUnit.toLowerCase();
    if ((u == 'g' || u == 'ml') && servingSize > 0) return servingSize;
    return null;
  }

  FoodRef get ref => FoodRef(id: id, name: name, brand: brand, basis: basis);
}

extension FoodLogEntryX on FoodLogEntry {
  Nutrients get nutrients => Nutrients(
    calories: calories,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
    fiber: fiberG,
  );

  LogLine get line => LogLine(
    localDate: localDate,
    mealType: mealType,
    nutrients: nutrients,
    verification: verification,
    deleted: deletedAt != null,
    name: name,
    foodId: foodId ?? recipeId,
  );

  FoodLogCsvRow get csvRow => FoodLogCsvRow(
    localDate: localDate,
    loggedAtUtc: loggedAt,
    mealType: mealType,
    name: name,
    brand: brand,
    servings: servings,
    grams: grams,
    calories: calories,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
    fiber: fiberG,
    source: source,
    verification: verification,
    note: note,
  );
}

extension RecipeIngredientX on RecipeIngredient {
  Nutrients get nutrients => Nutrients(
    calories: calories,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
    fiber: fiberG,
  );
}

extension SavedMealItemX on SavedMealItem {
  Nutrients get nutrients => Nutrients(
    calories: calories,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
    fiber: fiberG,
  );
}
