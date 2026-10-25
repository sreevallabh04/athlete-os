import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/running_models.dart';

/// Read/write access to `CardioActivities` for all sources. Strava rows are
/// subject to the 7-day cache rule and must never reach an AI provider.
class CardioRepository {
  CardioRepository(this._db);
  final AppDatabase _db;

  static RunActivity toActivity(CardioActivity a) => RunActivity(
    id: a.id,
    source: a.source,
    externalId: a.externalId,
    name: a.name,
    sportType: a.sportType,
    startAt: a.startAt,
    localDate: a.localDate,
    distanceM: a.distanceM,
    movingTimeS: a.movingTimeS,
    elapsedTimeS: a.elapsedTimeS,
    avgHr: a.avgHeartRate,
    maxHr: a.maxHeartRate,
    elevationGainM: a.elevationGainM,
    splits: RunSplit.listFromJson(a.splitsJson),
    fetchedAt: a.fetchedAt,
  );

  Stream<List<RunActivity>> watchAll() =>
      (_db.select(_db.cardioActivities)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.desc(c.startAt)]))
          .watch()
          .map((rows) => rows.map(toActivity).toList());

  Future<List<RunActivity>> all() async =>
      (await (_db.select(_db.cardioActivities)
                ..where((c) => c.deletedAt.isNull())
                ..orderBy([(c) => OrderingTerm.desc(c.startAt)]))
              .get())
          .map(toActivity)
          .toList();

  Future<CardioActivity?> getRow(String id) => (_db.select(
    _db.cardioActivities,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Stream<CardioActivity?> watchRow(String id) => (_db.select(
    _db.cardioActivities,
  )..where((c) => c.id.equals(id))).watchSingleOrNull();

  Future<List<CardioActivity>> sourceRows(String source) => (_db.select(
    _db.cardioActivities,
  )..where((c) => c.source.equals(source))).get();

  Future<int> countSource(String source) async =>
      (await sourceRows(source)).length;

  /// Inserts or updates a Strava summary row. Existing detail (splits/laps)
  /// is kept only while it is younger than [detailMaxAge].
  Future<void> upsertStravaSummary(
    CardioActivitiesCompanion summary, {
    required DateTime now,
    Duration detailMaxAge = const Duration(days: 7),
  }) async {
    final id = summary.id.value;
    final existing = await getRow(id);
    var companion = summary;
    if (existing != null) {
      final detailAt = stravaDetailFetchedAt(existing.rawJson);
      final detailFresh =
          detailAt != null && now.difference(detailAt) < detailMaxAge;
      companion = summary.copyWith(
        splitsJson: Value(detailFresh ? existing.splitsJson : null),
        lapsJson: Value(detailFresh ? existing.lapsJson : null),
        rawJson: Value(
          jsonEncode({
            if (detailFresh)
              'detail_fetched_at': detailAt.toUtc().toIso8601String(),
          }),
        ),
        createdAt: Value(existing.createdAt),
      );
    }
    await _db.into(_db.cardioActivities).insertOnConflictUpdate(companion);
  }

  Future<void> updateStravaDetail(
    String id, {
    required String? splitsJson,
    required String? lapsJson,
    required DateTime fetchedAt,
    double? maxHr,
    double? calories,
  }) => (_db.update(_db.cardioActivities)..where((c) => c.id.equals(id))).write(
    CardioActivitiesCompanion(
      splitsJson: Value(splitsJson),
      lapsJson: Value(lapsJson),
      rawJson: Value(
        jsonEncode({'detail_fetched_at': fetchedAt.toUtc().toIso8601String()}),
      ),
      fetchedAt: Value(fetchedAt.toUtc()),
      updatedAt: Value(fetchedAt.toUtc()),
      maxHeartRate: maxHr == null ? const Value.absent() : Value(maxHr),
      calories: calories == null ? const Value.absent() : Value(calories),
    ),
  );

  /// Hard-deletes every row of [source].
  Future<int> deleteSource(String source) => (_db.delete(
    _db.cardioActivities,
  )..where((c) => c.source.equals(source))).go();

  Future<int> deleteIds(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return Future.value(0);
    return (_db.delete(
      _db.cardioActivities,
    )..where((c) => c.id.isIn(list))).go();
  }

  /// Strava §6.2: delete strava rows not refreshed within [maxAge].
  Future<int> purgeStaleStrava(
    DateTime now, {
    Duration maxAge = const Duration(days: 7),
  }) =>
      (_db.delete(_db.cardioActivities)..where(
            (c) =>
                c.source.equals('strava') &
                c.fetchedAt.isSmallerThanValue(now.toUtc().subtract(maxAge)),
          ))
          .go();
}

DateTime? stravaDetailFetchedAt(String? rawJson) {
  if (rawJson == null) return null;
  try {
    final m = jsonDecode(rawJson);
    if (m is Map) {
      return DateTime.tryParse(m['detail_fetched_at']?.toString() ?? '');
    }
  } on FormatException {
    return null;
  }
  return null;
}

final cardioRepositoryProvider = Provider<CardioRepository>(
  (ref) => CardioRepository(ref.watch(databaseProvider)),
);
