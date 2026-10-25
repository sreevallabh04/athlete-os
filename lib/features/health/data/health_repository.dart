import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../domain/health_types.dart';
import '../domain/steps_math.dart';

/// Drift access for Health Connect imports and manual health entries.
class HealthRepository {
  HealthRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  // -------------------------------------------------------------------------
  // Daily summaries
  // -------------------------------------------------------------------------

  /// Replaces all [origin] rows of [type] between [startDate] and [endDate]
  /// (inclusive) with [values]. Used by sync so re-imports are idempotent and
  /// data deleted in Health Connect disappears here too.
  Future<void> replaceDailySummaries({
    required String type,
    required String unit,
    required String startDate,
    required String endDate,
    required Map<String, ({double value, String? sources})> values,
    String origin = HealthKeys.originHc,
  }) async {
    final now = _nowUtc;
    await _db.transaction(() async {
      await (_db.delete(_db.dailyHealthSummaries)..where(
            (s) =>
                s.type.equals(type) &
                s.origin.equals(origin) &
                s.localDate.isBetweenValues(startDate, endDate),
          ))
          .go();
      for (final e in values.entries) {
        await _db
            .into(_db.dailyHealthSummaries)
            .insertOnConflictUpdate(
              DailyHealthSummariesCompanion.insert(
                localDate: e.key,
                type: type,
                value: e.value.value,
                unit: unit,
                origin: origin,
                sourcesSummary: Value(e.value.sources),
                computedAt: Value(now),
              ),
            );
      }
    });
  }

  Future<void> upsertDailySummary({
    required String localDate,
    required String type,
    required double value,
    required String unit,
    required String origin,
    String? sources,
  }) => _db
      .into(_db.dailyHealthSummaries)
      .insertOnConflictUpdate(
        DailyHealthSummariesCompanion.insert(
          localDate: localDate,
          type: type,
          value: value,
          unit: unit,
          origin: origin,
          sourcesSummary: Value(sources),
          computedAt: Value(_nowUtc),
        ),
      );

  Stream<List<DailyHealthSummary>> watchSummaries(
    String type,
    String startDate,
    String endDate,
  ) =>
      (_db.select(_db.dailyHealthSummaries)
            ..where(
              (s) =>
                  s.type.equals(type) &
                  s.localDate.isBetweenValues(startDate, endDate),
            )
            ..orderBy([(s) => OrderingTerm.asc(s.localDate)]))
          .watch();

  Future<List<DailyHealthSummary>> summaries(
    String type,
    String startDate,
    String endDate,
  ) =>
      (_db.select(_db.dailyHealthSummaries)..where(
            (s) =>
                s.type.equals(type) &
                s.localDate.isBetweenValues(startDate, endDate),
          ))
          .get();

  // -------------------------------------------------------------------------
  // Steps (Health Connect + manual)
  // -------------------------------------------------------------------------

  Future<void> setManualSteps(String localDate, int steps) {
    if (steps < 0 || steps > 200000) {
      throw ArgumentError.value(steps, 'steps', 'must be 0..200000');
    }
    return upsertDailySummary(
      localDate: localDate,
      type: HealthKeys.steps,
      value: steps.toDouble(),
      unit: 'count',
      origin: HealthKeys.originManual,
      sources: 'Entered manually',
    );
  }

  Future<void> deleteManualSteps(String localDate) =>
      (_db.delete(_db.dailyHealthSummaries)..where(
            (s) =>
                s.localDate.equals(localDate) &
                s.type.equals(HealthKeys.steps) &
                s.origin.equals(HealthKeys.originManual),
          ))
          .go();

  /// Resolved steps for each day in [startDate, endDate] (null = no data),
  /// applying the Health Connect-over-manual precedence rule.
  static Map<String, DaySteps?> resolveSteps(
    List<DailyHealthSummary> rows,
    String startDate,
    String endDate,
  ) {
    final hc = <String, DailyHealthSummary>{};
    final manual = <String, DailyHealthSummary>{};
    for (final r in rows) {
      if (r.type != HealthKeys.steps) continue;
      (r.origin == HealthKeys.originManual ? manual : hc)[r.localDate] = r;
    }
    return {
      for (final d in LocalDates.range(startDate, endDate))
        d: resolveDaySteps(
          healthConnect: hc[d]?.value.round(),
          manual: manual[d]?.value.round(),
          hcSourcesSummary: hc[d]?.sourcesSummary,
          hcComputedAt: hc[d]?.computedAt,
          manualComputedAt: manual[d]?.computedAt,
        ),
    };
  }

  Stream<Map<String, DaySteps?>> watchResolvedSteps(
    String startDate,
    String endDate,
  ) => watchSummaries(
    HealthKeys.steps,
    startDate,
    endDate,
  ).map((rows) => resolveSteps(rows, startDate, endDate));

  Future<DaySteps?> stepsForDay(String localDate) async {
    final rows = await summaries(HealthKeys.steps, localDate, localDate);
    return resolveSteps(rows, localDate, localDate)[localDate];
  }

  // -------------------------------------------------------------------------
  // Samples
  // -------------------------------------------------------------------------

  /// Replaces Health Connect samples of [type] starting at or after
  /// [windowStart] with [rows] (stable ids → idempotent).
  Future<void> replaceSamples({
    required String type,
    required DateTime windowStart,
    required List<HealthSamplesCompanion> rows,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.healthSamples)..where(
            (s) =>
                s.type.equals(type) &
                s.origin.equals(HealthKeys.originHc) &
                s.startAt.isBiggerOrEqualValue(windowStart.toUtc()),
          ))
          .go();
      for (final r in rows) {
        await _db.into(_db.healthSamples).insertOnConflictUpdate(r);
      }
    });
  }

  HealthSamplesCompanion hcSample({
    required String type,
    required String externalId,
    required double value,
    required String unit,
    required DateTime start,
    required DateTime end,
    required String sourceApp,
    String sourceDevice = 'unknown',
    Map<String, Object?>? metadata,
    String? localDate,
  }) => HealthSamplesCompanion.insert(
    id: stableId('hc:$type', externalId),
    type: type,
    value: value,
    unit: unit,
    startAt: start.toUtc(),
    endAt: end.toUtc(),
    localDate: localDate ?? LocalDates.key(start),
    sourceApp: Value(sourceApp),
    sourceDevice: Value(sourceDevice),
    origin: HealthKeys.originHc,
    externalId: Value(externalId),
    metadataJson: Value(metadata == null ? null : jsonEncode(metadata)),
    syncedAt: Value(_nowUtc),
  );

  Future<String> addManualWeight(double kg, {DateTime? at, String? note}) {
    if (!(kg >= 20 && kg <= 400)) {
      throw ArgumentError.value(kg, 'kg', 'must be 20..400 kg');
    }
    final t = at ?? _clock.now();
    final id = newId();
    return _db
        .into(_db.healthSamples)
        .insert(
          HealthSamplesCompanion.insert(
            id: id,
            type: HealthKeys.weight,
            value: kg,
            unit: 'kg',
            startAt: t.toUtc(),
            endAt: t.toUtc(),
            localDate: LocalDates.key(t),
            sourceApp: const Value(null),
            sourceDevice: const Value('manual'),
            origin: HealthKeys.originManual,
            externalId: Value(id),
            metadataJson: Value(
              note == null ? null : jsonEncode({'note': note}),
            ),
            syncedAt: Value(_nowUtc),
          ),
        )
        .then((_) => id);
  }

  Future<void> deleteManualSample(String id) =>
      (_db.delete(_db.healthSamples)..where(
            (s) => s.id.equals(id) & s.origin.equals(HealthKeys.originManual),
          ))
          .go();

  Stream<List<HealthSample>> watchSamples(
    String type, {
    DateTime? since,
    int limit = 500,
    bool newestFirst = true,
  }) {
    final q = _db.select(_db.healthSamples)
      ..where(
        (s) =>
            s.type.equals(type) &
            (since == null
                ? const Constant(true)
                : s.startAt.isBiggerOrEqualValue(since.toUtc())),
      )
      ..orderBy([
        (s) => newestFirst
            ? OrderingTerm.desc(s.startAt)
            : OrderingTerm.asc(s.startAt),
      ])
      ..limit(limit);
    return q.watch();
  }

  Future<HealthSample?> latestSample(String type) =>
      (_db.select(_db.healthSamples)
            ..where((s) => s.type.equals(type))
            ..orderBy([(s) => OrderingTerm.desc(s.startAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<int> countSamples(String type) async {
    final c = countAll();
    final q = _db.selectOnly(_db.healthSamples)
      ..addColumns([c])
      ..where(_db.healthSamples.type.equals(type));
    return (await q.getSingle()).read(c) ?? 0;
  }

  // -------------------------------------------------------------------------
  // Cardio
  // -------------------------------------------------------------------------

  /// Inserts or updates a Health Connect cardio activity keyed by its HC
  /// uuid. Soft-deleted rows stay deleted (deletedAt is never touched).
  Future<void> upsertHcCardio(CardioActivitiesCompanion row) =>
      _db.into(_db.cardioActivities).insertOnConflictUpdate(row);

  Future<int> countCardio(String source) async {
    final c = countAll();
    final q = _db.selectOnly(_db.cardioActivities)
      ..addColumns([c])
      ..where(_db.cardioActivities.source.equals(source));
    return (await q.getSingle()).read(c) ?? 0;
  }
}
