import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';
import 'food_log_repository.dart';
import 'mappers.dart';

/// One ingredient line with its nutrient snapshot for the amount used.
class IngredientDraft {
  const IngredientDraft({
    required this.name,
    required this.nutrients,
    required this.verification,
    this.foodId,
    this.servings = 1,
    this.grams,
  });

  factory IngredientDraft.fromFood(Food food, Amount amount) {
    final r = resolveAmount(food.basis, amount);
    return IngredientDraft(
      name: food.name,
      foodId: food.id,
      servings: r.servings,
      grams: r.grams,
      nutrients: r.nutrients,
      verification: food.verification,
    );
  }

  final String name;
  final String? foodId;
  final double servings;
  final double? grams;
  final Nutrients nutrients;
  final String verification;
}

class RecipeWithIngredients {
  const RecipeWithIngredients(this.recipe, this.ingredients);
  final Recipe recipe;
  final List<RecipeIngredient> ingredients;

  Nutrients get total =>
      ingredients.fold(Nutrients.zero, (a, i) => a + i.nutrients);

  Nutrients get perServing =>
      recipePerServing(ingredients.map((i) => i.nutrients), recipe.servings);

  String get verification =>
      Verifications.weakest(ingredients.map((i) => i.verification));
}

class RecipeRepository {
  RecipeRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  Future<String> create({
    required String name,
    required double servings,
    required List<IngredientDraft> ingredients,
    String? notes,
  }) async {
    _validate(name, servings, ingredients);
    final id = newId();
    await _db.transaction(() async {
      await _db
          .into(_db.recipes)
          .insert(
            RecipesCompanion.insert(
              id: id,
              name: name.trim(),
              servings: Value(servings),
              notes: Value(notes),
              createdAt: Value(_nowUtc),
              updatedAt: Value(_nowUtc),
            ),
          );
      await _insertIngredients(id, ingredients);
    });
    return id;
  }

  Future<void> update(
    String id, {
    required String name,
    required double servings,
    required List<IngredientDraft> ingredients,
    String? notes,
  }) async {
    _validate(name, servings, ingredients);
    await _db.transaction(() async {
      await (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
        RecipesCompanion(
          name: Value(name.trim()),
          servings: Value(servings),
          notes: Value(notes),
          updatedAt: Value(_nowUtc),
        ),
      );
      await (_db.delete(
        _db.recipeIngredients,
      )..where((i) => i.recipeId.equals(id))).go();
      await _insertIngredients(id, ingredients);
    });
  }

  void _validate(String name, double servings, List<IngredientDraft> ing) {
    if (name.trim().isEmpty) throw ArgumentError('Recipe needs a name');
    if (!servings.isFinite || servings <= 0) {
      throw ArgumentError.value(servings, 'servings', 'must be > 0');
    }
    if (ing.isEmpty) throw ArgumentError('Add at least one ingredient');
  }

  Future<void> _insertIngredients(
    String recipeId,
    List<IngredientDraft> ingredients,
  ) async {
    for (var i = 0; i < ingredients.length; i++) {
      final d = ingredients[i];
      final n = d.nutrients.rounded();
      await _db
          .into(_db.recipeIngredients)
          .insert(
            RecipeIngredientsCompanion.insert(
              id: newId(),
              recipeId: recipeId,
              foodId: Value(d.foodId),
              name: d.name,
              servings: Value(d.servings),
              grams: Value(d.grams),
              calories: n.calories,
              proteinG: Value(n.protein),
              carbsG: Value(n.carbs),
              fatG: Value(n.fat),
              fiberG: Value(n.fiber),
              verification: Value(d.verification),
              position: Value(i),
            ),
          );
    }
  }

  Future<void> softDelete(String id) =>
      (_db.update(_db.recipes)..where((r) => r.id.equals(id))).write(
        RecipesCompanion(deletedAt: Value(_nowUtc), updatedAt: Value(_nowUtc)),
      );

  Future<RecipeWithIngredients?> get(String id) async {
    final r = await (_db.select(
      _db.recipes,
    )..where((x) => x.id.equals(id) & x.deletedAt.isNull())).getSingleOrNull();
    if (r == null) return null;
    final ing =
        await (_db.select(_db.recipeIngredients)
              ..where((i) => i.recipeId.equals(id))
              ..orderBy([(i) => OrderingTerm.asc(i.position)]))
            .get();
    return RecipeWithIngredients(r, ing);
  }

  Stream<List<RecipeWithIngredients>> watchAll() =>
      _db.select(_db.recipes).watch().asyncMap((_) => all());

  Future<List<RecipeWithIngredients>> all() async {
    final recipes =
        await (_db.select(_db.recipes)
              ..where((r) => r.deletedAt.isNull())
              ..orderBy([(r) => OrderingTerm.asc(r.name)]))
            .get();
    if (recipes.isEmpty) return const [];
    final ing =
        await (_db.select(_db.recipeIngredients)
              ..where((i) => i.recipeId.isIn(recipes.map((r) => r.id)))
              ..orderBy([(i) => OrderingTerm.asc(i.position)]))
            .get();
    return [
      for (final r in recipes)
        RecipeWithIngredients(r, ing.where((i) => i.recipeId == r.id).toList()),
    ];
  }

  /// Logs [servings] servings of a recipe with a per-serving snapshot.
  Future<String> logRecipe(
    FoodLogRepository log,
    String recipeId, {
    required double servings,
    required MealType mealType,
    required String localDate,
  }) async {
    final r = await get(recipeId);
    if (r == null) throw StateError('Recipe not found');
    if (!servings.isFinite || servings <= 0) {
      throw ArgumentError.value(servings, 'servings', 'must be > 0');
    }
    return log.log(
      LogDraft(
        name: r.recipe.name,
        mealType: mealType,
        nutrients: r.perServing.scale(servings),
        servings: servings,
        source: FoodSources.recipe,
        verification: r.verification,
        recipeId: r.recipe.id,
      ),
      localDate: localDate,
    );
  }
}
