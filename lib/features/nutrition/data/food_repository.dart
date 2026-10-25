import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../domain/food_models.dart';

/// Local food definitions: CRUD, search, favorites, recents, barcode lookup.
class FoodRepository {
  FoodRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  Future<Food> create(FoodDraft d, {String? id}) async {
    final rowId = id ?? newId();
    final now = _nowUtc;
    await _db
        .into(_db.foods)
        .insert(
          FoodsCompanion.insert(
            id: rowId,
            name: d.name.trim(),
            brand: Value(_blank(d.brand)),
            barcode: Value(_blank(d.barcode)),
            servingSize: Value(d.basis.servingSize),
            servingUnit: Value(d.basis.servingUnit),
            gramsPerServing: Value(d.basis.gramsPerServing),
            calories: d.basis.perServing.calories,
            proteinG: Value(d.basis.perServing.protein),
            carbsG: Value(d.basis.perServing.carbs),
            fatG: Value(d.basis.perServing.fat),
            fiberG: Value(d.basis.perServing.fiber),
            source: d.source,
            sourceId: Value(d.sourceId),
            verification: d.verification,
            isFavorite: Value(d.isFavorite),
            rawJson: Value(d.rawJson),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return (await get(rowId))!;
  }

  Future<void> update(String id, FoodDraft d) async {
    await (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
      FoodsCompanion(
        name: Value(d.name.trim()),
        brand: Value(_blank(d.brand)),
        barcode: Value(_blank(d.barcode)),
        servingSize: Value(d.basis.servingSize),
        servingUnit: Value(d.basis.servingUnit),
        gramsPerServing: Value(d.basis.gramsPerServing),
        calories: Value(d.basis.perServing.calories),
        proteinG: Value(d.basis.perServing.protein),
        carbsG: Value(d.basis.perServing.carbs),
        fatG: Value(d.basis.perServing.fat),
        fiberG: Value(d.basis.perServing.fiber),
        verification: Value(d.verification),
        updatedAt: Value(_nowUtc),
      ),
    );
  }

  /// Saves a remote candidate locally (idempotent per provider + id) and
  /// returns the stored food. Throws [StateError] for incomplete candidates.
  Future<Food> saveCandidate(
    FoodCandidate c, {
    required String verification,
  }) async {
    final basis = c.toBasis();
    if (basis == null) {
      throw StateError('Incomplete nutrition data; enter values manually.');
    }
    final id = stableId(c.source, c.sourceId);
    final existing = await get(id, includeDeleted: true);
    final draft = FoodDraft(
      name: c.name,
      brand: c.brand,
      barcode: c.barcode,
      basis: basis,
      source: c.source,
      sourceId: c.sourceId,
      verification: verification,
      rawJson: jsonEncode({
        ...c.raw,
        if (c.energyFromKj) 'energy_kcal_derived_from_kj': true,
      }),
    );
    if (existing == null) return create(draft, id: id);
    await update(id, draft);
    await (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
      FoodsCompanion(
        deletedAt: const Value(null),
        rawJson: Value(draft.rawJson),
      ),
    );
    return (await get(id))!;
  }

  Future<Food?> get(String id, {bool includeDeleted = false}) =>
      (_db.select(_db.foods)..where(
            (f) =>
                f.id.equals(id) &
                (includeDeleted ? const Constant(true) : f.deletedAt.isNull()),
          ))
          .getSingleOrNull();

  Future<void> softDelete(String id) =>
      (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
        FoodsCompanion(deletedAt: Value(_nowUtc), updatedAt: Value(_nowUtc)),
      );

  Future<void> setFavorite(String id, bool favorite) =>
      (_db.update(_db.foods)..where((f) => f.id.equals(id))).write(
        FoodsCompanion(isFavorite: Value(favorite), updatedAt: Value(_nowUtc)),
      );

  /// Case-insensitive name/brand search over local, non-deleted foods.
  Future<List<Food>> search(String query, {int limit = 30}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return Future.value(const []);
    final pattern = '%${_escapeLike(q)}%';
    return (_db.select(_db.foods)
          ..where(
            (f) =>
                f.deletedAt.isNull() &
                (f.name.lower().like(pattern, escapeChar: r'\') |
                    f.brand.lower().like(pattern, escapeChar: r'\')),
          )
          ..orderBy([
            (f) => OrderingTerm.desc(f.isFavorite),
            (f) => OrderingTerm.asc(f.name),
          ])
          ..limit(limit))
        .get();
  }

  /// Local barcode lookup (barcode lookup is local-first).
  Future<Food?> byBarcode(String barcode) async {
    final rows =
        await (_db.select(_db.foods)
              ..where(
                (f) => f.barcode.equals(barcode.trim()) & f.deletedAt.isNull(),
              )
              ..orderBy([(f) => OrderingTerm.desc(f.updatedAt)])
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.first;
  }

  Stream<List<Food>> watchFavorites() =>
      (_db.select(_db.foods)
            ..where((f) => f.deletedAt.isNull() & f.isFavorite.equals(true))
            ..orderBy([(f) => OrderingTerm.asc(f.name)]))
          .watch();

  /// All active local foods (saved from search, scanned or user-created).
  Stream<List<Food>> watchAll() =>
      (_db.select(_db.foods)
            ..where((f) => f.deletedAt.isNull())
            ..orderBy([(f) => OrderingTerm.asc(f.name)]))
          .watch();

  Future<List<Food>> all() =>
      (_db.select(_db.foods)
            ..where((f) => f.deletedAt.isNull())
            ..orderBy([(f) => OrderingTerm.asc(f.name)]))
          .get();

  /// Distinct foods from the log, most recently logged first.
  Future<List<Food>> recents({int limit = 25}) async {
    final rows =
        await (_db.select(_db.foodLogEntries)
              ..where((e) => e.deletedAt.isNull() & e.foodId.isNotNull())
              ..orderBy([(e) => OrderingTerm.desc(e.loggedAt)])
              ..limit(400))
            .get();
    final ids = <String>[];
    for (final r in rows) {
      if (!ids.contains(r.foodId)) ids.add(r.foodId!);
      if (ids.length >= limit) break;
    }
    if (ids.isEmpty) return const [];
    final foods = await (_db.select(
      _db.foods,
    )..where((f) => f.id.isIn(ids) & f.deletedAt.isNull())).get();
    final byId = {for (final f in foods) f.id: f};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Stream<List<Food>> watchRecents({int limit = 25}) => _db
      .select(_db.foodLogEntries)
      .watch()
      .asyncMap((_) => recents(limit: limit));

  static String? _blank(String? s) =>
      s == null || s.trim().isEmpty ? null : s.trim();

  static String _escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}
