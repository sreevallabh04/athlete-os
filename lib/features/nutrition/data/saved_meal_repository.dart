import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import 'food_log_repository.dart';
import 'mappers.dart';

class SavedMealWithItems {
  const SavedMealWithItems(this.meal, this.items);
  final SavedMeal meal;
  final List<SavedMealItem> items;

  Nutrients get total => items.fold(Nutrients.zero, (a, i) => a + i.nutrients);

  bool get hasEstimates =>
      items.any((i) => Verifications.isEstimate(i.verification));
}

/// Meal templates ("my usual breakfast") that can be logged in one tap.
class SavedMealRepository {
  SavedMealRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  /// Creates a template from logged entries (their snapshots are copied).
  Future<String> createFromEntries(
    String name,
    List<FoodLogEntry> entries, {
    MealType? mealType,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Name required');
    if (entries.isEmpty) throw ArgumentError('Nothing to save');
    final id = newId();
    await _db.transaction(() async {
      await _db
          .into(_db.savedMeals)
          .insert(
            SavedMealsCompanion.insert(
              id: id,
              name: name.trim(),
              mealType: Value(mealType?.key),
              createdAt: Value(_nowUtc),
              updatedAt: Value(_nowUtc),
            ),
          );
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        await _db
            .into(_db.savedMealItems)
            .insert(
              SavedMealItemsCompanion.insert(
                id: newId(),
                savedMealId: id,
                // Recipe entries keep their name; recipe link is not stored
                // on items (schema), so they log as a snapshot.
                foodId: Value(e.foodId),
                name: e.name,
                servings: Value(e.servings),
                grams: Value(e.grams),
                calories: e.calories,
                proteinG: Value(e.proteinG),
                carbsG: Value(e.carbsG),
                fatG: Value(e.fatG),
                fiberG: Value(e.fiberG),
                verification: e.verification,
                position: Value(i),
              ),
            );
      }
    });
    return id;
  }

  Future<void> softDelete(String id) =>
      (_db.update(_db.savedMeals)..where((m) => m.id.equals(id))).write(
        SavedMealsCompanion(
          deletedAt: Value(_nowUtc),
          updatedAt: Value(_nowUtc),
        ),
      );

  Future<SavedMealWithItems?> get(String id) async {
    final m = await (_db.select(
      _db.savedMeals,
    )..where((x) => x.id.equals(id) & x.deletedAt.isNull())).getSingleOrNull();
    if (m == null) return null;
    final items =
        await (_db.select(_db.savedMealItems)
              ..where((i) => i.savedMealId.equals(id))
              ..orderBy([(i) => OrderingTerm.asc(i.position)]))
            .get();
    return SavedMealWithItems(m, items);
  }

  Future<List<SavedMealWithItems>> all() async {
    final meals =
        await (_db.select(_db.savedMeals)
              ..where((m) => m.deletedAt.isNull())
              ..orderBy([(m) => OrderingTerm.asc(m.name)]))
            .get();
    if (meals.isEmpty) return const [];
    final items =
        await (_db.select(_db.savedMealItems)
              ..where((i) => i.savedMealId.isIn(meals.map((m) => m.id)))
              ..orderBy([(i) => OrderingTerm.asc(i.position)]))
            .get();
    return [
      for (final m in meals)
        SavedMealWithItems(
          m,
          items.where((i) => i.savedMealId == m.id).toList(),
        ),
    ];
  }

  Stream<List<SavedMealWithItems>> watchAll() =>
      _db.select(_db.savedMeals).watch().asyncMap((_) => all());

  /// Logs every item of a saved meal in one go. Returns created entry ids.
  Future<List<String>> logSavedMeal(
    FoodLogRepository log,
    String savedMealId, {
    required MealType mealType,
    required String localDate,
  }) async {
    final m = await get(savedMealId);
    if (m == null) throw StateError('Saved meal not found');
    final foodIds = m.items.map((i) => i.foodId).whereType<String>().toSet();
    final foods = foodIds.isEmpty
        ? const <Food>[]
        : await (_db.select(_db.foods)..where((f) => f.id.isIn(foodIds))).get();
    final sourceByFood = {for (final f in foods) f.id: f.source};
    final ids = <String>[];
    await _db.transaction(() async {
      for (final i in m.items) {
        ids.add(
          await log.log(
            LogDraft(
              name: i.name,
              mealType: mealType,
              nutrients: i.nutrients,
              servings: i.servings,
              grams: i.grams,
              source: sourceByFood[i.foodId] ?? FoodSources.custom,
              verification: i.verification,
              foodId: i.foodId,
              note: 'From saved meal "${m.meal.name}"',
            ),
            localDate: localDate,
          ),
        );
      }
    });
    return ids;
  }
}
