import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import 'device_tz.dart';
import 'mappers.dart';

/// Values for a new log entry. Nutrients are a snapshot for the eaten amount.
class LogDraft {
  const LogDraft({
    required this.name,
    required this.mealType,
    required this.nutrients,
    required this.source,
    required this.verification,
    this.brand,
    this.servings = 1,
    this.grams,
    this.foodId,
    this.recipeId,
    this.note,
  });

  final String name;
  final String? brand;
  final MealType mealType;
  final Nutrients nutrients;
  final double servings;
  final double? grams;
  final String source;
  final String verification;
  final String? foodId;
  final String? recipeId;
  final String? note;
}

/// The food diary. Every entry stores a nutrient snapshot plus source and
/// verification so history never changes when a food definition is edited.
class FoodLogRepository {
  FoodLogRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  /// Instant to stamp on an entry logged for [localDate]: now when the date is
  /// today, otherwise that date at the current local time of day.
  DateTime loggedAtFor(String localDate) {
    final now = _clock.now();
    if (LocalDates.key(now) == localDate) return now.toUtc();
    final d = LocalDates.parse(localDate);
    final local = now.isUtc ? now.toLocal() : now;
    return DateTime(d.year, d.month, d.day, local.hour, local.minute).toUtc();
  }

  Future<String> log(
    LogDraft d, {
    required String localDate,
    String? id,
  }) async {
    final rowId = id ?? newId();
    final n = d.nutrients.rounded();
    final now = _nowUtc;
    await _db
        .into(_db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: rowId,
            foodId: Value(d.foodId),
            recipeId: Value(d.recipeId),
            name: d.name.trim().isEmpty ? 'Food' : d.name.trim(),
            brand: Value(d.brand),
            mealType: d.mealType.key,
            servings: Value(d.servings),
            grams: Value(d.grams),
            calories: n.calories,
            proteinG: Value(n.protein),
            carbsG: Value(n.carbs),
            fatG: Value(n.fat),
            fiberG: Value(n.fiber),
            source: d.source,
            verification: d.verification,
            loggedAt: loggedAtFor(localDate),
            localDate: localDate,
            tzName: DeviceTz.name(_clock.now()),
            note: Value(d.note),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return rowId;
  }

  /// Logs [amount] of a local [food] (snapshot computed now).
  Future<String> logFood(
    Food food, {
    required Amount amount,
    required MealType mealType,
    required String localDate,
    String? note,
  }) {
    final r = resolveAmount(food.basis, amount);
    return log(
      LogDraft(
        name: food.name,
        brand: food.brand,
        mealType: mealType,
        nutrients: r.nutrients,
        servings: r.servings,
        grams: r.grams,
        source: food.source,
        verification: food.verification,
        foodId: food.id,
        note: note,
      ),
      localDate: localDate,
    );
  }

  /// Quick add: user-typed calories/macros. Marked as an estimate unless the
  /// user says the values are exact (e.g. copied from a label).
  Future<String> quickAdd({
    required String name,
    required Nutrients nutrients,
    required MealType mealType,
    required String localDate,
    bool isEstimate = true,
  }) => log(
    LogDraft(
      name: name.trim().isEmpty ? 'Quick add' : name,
      mealType: mealType,
      nutrients: nutrients,
      source: FoodSources.quickAdd,
      verification: isEstimate
          ? Verifications.estimate
          : Verifications.userEntered,
    ),
    localDate: localDate,
  );

  Future<FoodLogEntry?> get(String id) => (_db.select(
    _db.foodLogEntries,
  )..where((e) => e.id.equals(id))).getSingleOrNull();

  /// Edits amount and/or meal. Changing the amount rescales the stored
  /// snapshot proportionally (the original per-serving basis is preserved).
  Future<void> updateEntry(
    String id, {
    double? servings,
    MealType? mealType,
    String? localDate,
    String? note,
  }) async {
    final e = await get(id);
    if (e == null) return;
    var companion = FoodLogEntriesCompanion(updatedAt: Value(_nowUtc));
    if (servings != null) {
      if (!servings.isFinite || servings <= 0) {
        throw ArgumentError.value(servings, 'servings', 'must be > 0');
      }
      if (e.servings <= 0) {
        throw StateError('Entry has no amount to rescale.');
      }
      final f = servings / e.servings;
      final n = e.nutrients.scale(f).rounded();
      companion = companion.copyWith(
        servings: Value(servings),
        grams: Value(e.grams == null ? null : e.grams! * f),
        calories: Value(n.calories),
        proteinG: Value(n.protein),
        carbsG: Value(n.carbs),
        fatG: Value(n.fat),
        fiberG: Value(n.fiber),
      );
    }
    if (mealType != null) {
      companion = companion.copyWith(mealType: Value(mealType.key));
    }
    if (localDate != null && localDate != e.localDate) {
      companion = companion.copyWith(
        localDate: Value(localDate),
        loggedAt: Value(loggedAtFor(localDate)),
      );
    }
    if (note != null) {
      companion = companion.copyWith(
        note: Value(note.trim().isEmpty ? null : note.trim()),
      );
    }
    await (_db.update(
      _db.foodLogEntries,
    )..where((x) => x.id.equals(id))).write(companion);
  }

  Future<void> softDelete(String id) =>
      (_db.update(_db.foodLogEntries)..where((e) => e.id.equals(id))).write(
        FoodLogEntriesCompanion(
          deletedAt: Value(_nowUtc),
          updatedAt: Value(_nowUtc),
        ),
      );

  /// Undo for [softDelete].
  Future<void> restore(String id) =>
      (_db.update(_db.foodLogEntries)..where((e) => e.id.equals(id))).write(
        FoodLogEntriesCompanion(
          deletedAt: const Value(null),
          updatedAt: Value(_nowUtc),
        ),
      );

  SimpleSelectStatement<$FoodLogEntriesTable, FoodLogEntry> _dayQuery(
    String localDate,
  ) => _db.select(_db.foodLogEntries)
    ..where((e) => e.localDate.equals(localDate) & e.deletedAt.isNull())
    ..orderBy([(e) => OrderingTerm.asc(e.loggedAt)]);

  Stream<List<FoodLogEntry>> watchDay(String localDate) =>
      _dayQuery(localDate).watch();

  Future<List<FoodLogEntry>> day(String localDate) =>
      _dayQuery(localDate).get();

  SimpleSelectStatement<$FoodLogEntriesTable, FoodLogEntry> _rangeQuery(
    String start,
    String end,
  ) => _db.select(_db.foodLogEntries)
    ..where(
      (e) => e.localDate.isBetweenValues(start, end) & e.deletedAt.isNull(),
    )
    ..orderBy([
      (e) => OrderingTerm.asc(e.localDate),
      (e) => OrderingTerm.asc(e.loggedAt),
    ]);

  /// Inclusive date range, non-deleted entries.
  Future<List<FoodLogEntry>> range(String start, String end) =>
      _rangeQuery(start, end).get();

  Stream<List<FoodLogEntry>> watchRange(String start, String end) =>
      _rangeQuery(start, end).watch();

  /// Copies the non-deleted entries of [fromMeal] on [fromDate] (or the whole
  /// day when [fromMeal] is null) to [toDate] / [toMeal]. Snapshots are copied
  /// as-is. Returns the number of entries created.
  Future<int> copy({
    required String fromDate,
    required String toDate,
    MealType? fromMeal,
    MealType? toMeal,
  }) async {
    final source = await day(fromDate);
    final rows = fromMeal == null
        ? source
        : source.where((e) => e.mealType == fromMeal.key).toList();
    if (rows.isEmpty) return 0;
    await _db.transaction(() async {
      for (final e in rows) {
        await log(
          LogDraft(
            name: e.name,
            brand: e.brand,
            mealType: toMeal ?? MealType.fromKey(e.mealType),
            nutrients: e.nutrients,
            servings: e.servings,
            grams: e.grams,
            source: e.source,
            verification: e.verification,
            foodId: e.foodId,
            recipeId: e.recipeId,
            note: e.note,
          ),
          localDate: toDate,
        );
      }
    });
    return rows.length;
  }
}
