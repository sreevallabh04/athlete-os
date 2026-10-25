import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../core/util/redact.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../data/health_data_source.dart';
import '../data/health_repository.dart';
import '../data/health_settings.dart';
import '../domain/aggregation.dart';
import '../domain/health_types.dart';
import '../domain/sources.dart';

enum SyncTrigger { appStart, resume, pullToRefresh, manual, permissionChange }

enum SyncOutcome {
  /// Every permitted type synced.
  ok,

  /// Some types failed; the rest were imported.
  partial,

  /// Every permitted type failed.
  failed,

  /// Health Connect is not installed / needs an update / unsupported.
  unavailable,

  /// The user hasn't enabled any data group yet.
  notEnabled,

  /// Groups are enabled but no permission is currently granted (never
  /// granted, or revoked in Health Connect).
  notPermitted,

  /// Throttled (resume within the minimum interval).
  skipped,
}

class HealthSyncResult {
  const HealthSyncResult(
    this.outcome, {
    this.granted = const {},
    this.denied = const {},
    this.warnings = const [],
    this.windowDays = 0,
  });

  final SyncOutcome outcome;
  final Set<HcDataType> granted;
  final Set<HcDataType> denied;
  final List<String> warnings;
  final int windowDays;

  bool get imported =>
      outcome == SyncOutcome.ok || outcome == SyncOutcome.partial;
}

/// Foreground, idempotent Health Connect → local database sync.
///
/// * Never runs two syncs at once: concurrent callers share the in-flight
///   future.
/// * Re-checks permissions on every run (users can revoke at any time) and
///   records the result in [IntegrationStatusRepository].
/// * Writes are window-replacements keyed by stable ids, so running the same
///   sync twice yields identical rows.
/// * There is no background sync (we do not request
///   READ_HEALTH_DATA_IN_BACKGROUND). Data is only as fresh as the last sync.
class HealthSyncService {
  HealthSyncService({
    required HealthDataSource source,
    required HealthRepository repository,
    required this._status,
    required this._settings,
    required this._clock,
  }) : _ds = source,
       _repo = repository;

  final HealthDataSource _ds;
  final HealthRepository _repo;
  final IntegrationStatusRepository _status;
  final HealthSettings _settings;
  final Clock _clock;

  static const fullWindowDays = 30;
  static const incrementalWindowDays = 7;
  static const heartRateWindow = Duration(hours: 48);
  static const resumeMinInterval = Duration(minutes: 5);

  Future<HealthSyncResult>? _inFlight;
  DateTime? _lastRunAt;
  final _syncingCtrl = StreamController<bool>.broadcast();

  bool get isSyncing => _inFlight != null;
  Stream<bool> get syncingChanges => _syncingCtrl.stream;
  DateTime? get lastRunAt => _lastRunAt;

  void dispose() => _syncingCtrl.close();

  void _setSyncing(bool v) {
    if (!_syncingCtrl.isClosed) _syncingCtrl.add(v);
  }

  /// Runs a sync of the last [days] days (default: 30 on first sync, 7
  /// afterwards). Never throws.
  Future<HealthSyncResult> sync({
    int? days,
    SyncTrigger trigger = SyncTrigger.manual,
  }) {
    final running = _inFlight;
    if (running != null) return running;
    _setSyncing(true);
    final future = _guardedRun(days, trigger);
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
      _setSyncing(false);
    });
  }

  /// Sync unless one ran (or was attempted) within [minInterval].
  Future<HealthSyncResult> syncIfStale({
    Duration minInterval = resumeMinInterval,
    SyncTrigger trigger = SyncTrigger.resume,
  }) async {
    final now = _clock.now();
    var last = _lastRunAt;
    if (last == null) {
      try {
        last = (await _status.get(Providers.healthConnect))?.lastAttemptAt;
      } catch (_) {}
    }
    if (last != null && now.difference(last.toLocal()).abs() < minInterval) {
      return const HealthSyncResult(SyncOutcome.skipped);
    }
    return sync(trigger: trigger);
  }

  Future<HealthSyncResult> _guardedRun(int? days, SyncTrigger trigger) async {
    try {
      return await _run(days, trigger);
    } catch (e) {
      final msg = redactSecrets('Health Connect sync failed: $e');
      try {
        await _status.setStatus(
          Providers.healthConnect,
          ConnectionStates.error,
          error: msg,
        );
      } catch (_) {}
      return HealthSyncResult(SyncOutcome.failed, warnings: [msg]);
    } finally {
      _lastRunAt = _clock.now();
    }
  }

  Future<HealthSyncResult> _run(int? days, SyncTrigger trigger) async {
    final now = _clock.now();
    final sdk = await _ds.sdkStatus();
    final groups = await _settings.enabledGroups();
    final baseMeta = <String, Object?>{
      'sdk': sdk.name,
      'groups': [for (final g in groups) g.name],
      'trigger': trigger.name,
    };

    if (sdk != HcSdkStatus.available) {
      await _status.setStatus(
        Providers.healthConnect,
        ConnectionStates.needsSetup,
        error: 'Health Connect is ${sdk.label.toLowerCase()}.',
        meta: baseMeta,
      );
      return const HealthSyncResult(SyncOutcome.unavailable);
    }
    if (groups.isEmpty) {
      await _status.setStatus(
        Providers.healthConnect,
        ConnectionStates.needsSetup,
        scopes: const [],
        clearError: true,
        meta: baseMeta,
      );
      return const HealthSyncResult(SyncOutcome.notEnabled);
    }

    // Re-check permissions every run: the user can revoke them in Health
    // Connect at any time.
    final wanted = [
      for (final g in HealthGroup.values)
        if (groups.contains(g)) ...g.types,
    ];
    final granted = <HcDataType>{};
    for (final t in wanted) {
      if (await _ds.hasPermissions([t])) granted.add(t);
    }
    final denied = wanted.toSet().difference(granted);
    final history = await _ds.isHistoryAuthorized();
    final meta = {
      ...baseMeta,
      'granted': [for (final t in granted) t.name],
      'denied': [for (final t in denied) t.name],
      'history': history,
    };

    if (granted.isEmpty) {
      await _status.setStatus(
        Providers.healthConnect,
        ConnectionStates.needsSetup,
        scopes: const [],
        error:
            'Health Connect permissions are not granted or were revoked. '
            'Grant read access again from the Health Connect screen.',
        meta: meta,
      );
      return HealthSyncResult(SyncOutcome.notPermitted, denied: denied);
    }

    final existing = await _status.get(Providers.healthConnect);
    final windowDays =
        days ??
        (existing?.lastSyncAt == null ? fullWindowDays : incrementalWindowDays);
    final today = LocalDates.key(now);
    final startDate = LocalDates.addDays(today, -(windowDays - 1));
    final windowStart = LocalDates.parse(startDate);

    final warnings = <String>[];
    var attempted = 0;
    Future<void> part(String name, Future<void> Function() body) async {
      attempted++;
      try {
        await body();
      } catch (e) {
        warnings.add(redactSecrets('$name: $e'));
      }
    }

    bool has(HcDataType t) => granted.contains(t);

    if (has(HcDataType.steps)) {
      await part('steps', () => _syncSteps(startDate, today, now));
    }
    if (has(HcDataType.distance)) {
      await part(
        'distance',
        () => _syncDailyTotal(
          HcDataType.distance,
          HealthKeys.distance,
          'm',
          startDate,
          today,
          windowStart,
          now,
        ),
      );
    }
    if (has(HcDataType.activeCalories)) {
      await part(
        'active calories',
        () => _syncDailyTotal(
          HcDataType.activeCalories,
          HealthKeys.activeKcal,
          'kcal',
          startDate,
          today,
          windowStart,
          now,
        ),
      );
    }
    if (has(HcDataType.exercise)) {
      await part(
        'exercise',
        () => _syncExercise(
          startDate,
          today,
          windowStart,
          now,
          withHeartRate: has(HcDataType.heartRate),
        ),
      );
    }
    if (has(HcDataType.sleepSession)) {
      await part('sleep', () => _syncSleep(startDate, today, windowStart, now));
    }
    if (has(HcDataType.heartRate)) {
      await part('heart rate', () => _syncHeartRate(now));
    }
    if (has(HcDataType.restingHeartRate)) {
      await part(
        'resting heart rate',
        () => _syncInstants(
          HcDataType.restingHeartRate,
          HealthKeys.restingHeartRate,
          'bpm',
          windowStart,
          now,
        ),
      );
    }
    if (has(HcDataType.weight)) {
      await part(
        'weight',
        () => _syncInstants(
          HcDataType.weight,
          HealthKeys.weight,
          'kg',
          windowStart,
          now,
        ),
      );
    }

    final finalMeta = {
      ...meta,
      'window_days': windowDays,
      'warnings': warnings,
    };
    final scopes = [for (final t in granted) t.name];
    if (attempted > 0 && warnings.length == attempted) {
      final err = warnings.join('; ');
      await _status.setStatus(
        Providers.healthConnect,
        ConnectionStates.error,
        scopes: scopes,
        error: err,
        meta: finalMeta,
      );
      await _status.recordSync(Providers.healthConnect, error: err);
      return HealthSyncResult(
        SyncOutcome.failed,
        granted: granted,
        denied: denied,
        warnings: warnings,
        windowDays: windowDays,
      );
    }
    await _status.setStatus(
      Providers.healthConnect,
      ConnectionStates.connected,
      scopes: scopes,
      meta: finalMeta,
    );
    await _status.recordSync(Providers.healthConnect);
    return HealthSyncResult(
      warnings.isEmpty ? SyncOutcome.ok : SyncOutcome.partial,
      granted: granted,
      denied: denied,
      warnings: warnings,
      windowDays: windowDays,
    );
  }

  // ---------------------------------------------------------------------------

  Future<void> _syncSteps(String startDate, String today, DateTime now) async {
    // Contributing apps per day (best effort, last 7 days only to bound the
    // number of raw records read).
    final sourcesByDay = <String, Set<String>>{};
    try {
      final from = LocalDates.parse(
        LocalDates.addDays(today, -(incrementalWindowDays - 1)),
      );
      final sStart = LocalDates.parse(startDate);
      final raw = await _ds.read(
        HcDataType.steps,
        from.isAfter(sStart) ? from : sStart,
        now,
      );
      for (final r in raw) {
        if (r.value <= 0) continue;
        sourcesByDay
            .putIfAbsent(LocalDates.key(r.start), () => {})
            .add(r.sourceApp);
      }
    } catch (_) {
      // Non-fatal: totals still come from the aggregate API.
    }

    final values = <String, ({double value, String? sources})>{};
    var failedDays = 0;
    final days = LocalDates.range(startDate, today);
    for (final d in days) {
      final (s, e) = LocalDates.bounds(d);
      final end = e.isAfter(now) ? now : e;
      if (!end.isAfter(s)) continue;
      final total = await _ds.totalSteps(s, end);
      if (total == null) {
        failedDays++;
        continue;
      }
      // A zero for a past day means "no data" (e.g. beyond the 30-day
      // history limit), not "you walked zero steps" — don't store it.
      if (total <= 0 && d != today) continue;
      final src = sourcesByDay[d];
      values[d] = (
        value: total.toDouble(),
        sources: src == null || src.isEmpty ? null : sourcesLabel(src),
      );
    }
    if (failedDays == days.length) {
      throw StateError('Health Connect did not return step totals');
    }
    await _repo.replaceDailySummaries(
      type: HealthKeys.steps,
      unit: 'count',
      startDate: startDate,
      endDate: today,
      values: values,
    );
  }

  Future<void> _syncDailyTotal(
    HcDataType type,
    String key,
    String unit,
    String startDate,
    String today,
    DateTime windowStart,
    DateTime now,
  ) async {
    final records = await _ds.read(type, windowStart, now);
    final totals = dailyTotalsSingleSource(records);
    await _repo.replaceDailySummaries(
      type: key,
      unit: unit,
      startDate: startDate,
      endDate: today,
      values: {
        for (final t in totals.values)
          if (t.localDate.compareTo(startDate) >= 0 &&
              t.localDate.compareTo(today) <= 0 &&
              t.value > 0)
            t.localDate: (value: t.value, sources: t.sourcesSummary),
      },
    );
  }

  Future<void> _syncExercise(
    String startDate,
    String today,
    DateTime windowStart,
    DateTime now, {
    required bool withHeartRate,
  }) async {
    final sessions = dedupeByUuid(
      await _ds.read(HcDataType.exercise, windowStart, now),
    ).where((s) => s.uuid.isNotEmpty && s.end.isAfter(s.start)).toList();

    await _repo.replaceSamples(
      type: HealthKeys.exerciseSession,
      windowStart: windowStart,
      rows: [
        for (final s in sessions)
          _repo.hcSample(
            type: HealthKeys.exerciseSession,
            externalId: s.uuid,
            value: s.duration.inSeconds / 60,
            unit: 'min',
            start: s.start,
            end: s.end,
            sourceApp: s.sourceApp,
            sourceDevice: deviceTypeFromMetadata(s.metadata),
            metadata: {
              'workout_type': s.workoutType,
              'distance_m': s.totalDistanceM,
              'total_kcal': s.totalEnergyKcal,
              'steps': s.totalSteps,
            },
          ),
      ],
    );

    // Active minutes: union of session intervals per local day.
    final minutes = activeMinutesPerDay(sessions);
    final srcByDay = <String, Set<String>>{};
    for (final s in sessions) {
      srcByDay.putIfAbsent(LocalDates.key(s.start), () => {}).add(s.sourceApp);
    }
    await _repo.replaceDailySummaries(
      type: HealthKeys.activeMinutes,
      unit: 'min',
      startDate: startDate,
      endDate: today,
      values: {
        for (final e in minutes.entries)
          if (e.key.compareTo(startDate) >= 0 &&
              e.key.compareTo(today) <= 0 &&
              e.value > 0)
            e.key: (
              value: e.value.toDouble(),
              sources: srcByDay[e.key] == null
                  ? null
                  : sourcesLabel(srcByDay[e.key]!),
            ),
      },
    );

    // Cardio sessions → CardioActivities (idempotent by HC uuid).
    for (final s in sessions) {
      final sport = normaliseCardioSport(s.workoutType);
      if (sport == null) continue;
      double? avgHr;
      double? maxHr;
      if (withHeartRate) {
        try {
          final hr = await _ds.read(HcDataType.heartRate, s.start, s.end);
          final values = [
            for (final h in hr)
              if (!h.start.isBefore(s.start) && !h.start.isAfter(s.end))
                h.value,
          ];
          if (values.isNotEmpty) {
            avgHr = values.reduce((a, b) => a + b) / values.length;
            maxHr = values.reduce((a, b) => a > b ? a : b);
          }
        } catch (_) {
          // Heart rate is optional enrichment.
        }
      }
      final seconds = s.duration.inSeconds;
      final distance = (s.totalDistanceM ?? 0) > 0 ? s.totalDistanceM : null;
      await _repo.upsertHcCardio(
        CardioActivitiesCompanion.insert(
          id: stableId('cardio:${HealthKeys.originHc}', s.uuid),
          source: HealthKeys.originHc,
          externalId: Value(s.uuid),
          name: Value(
            '${workoutLabel(s.workoutType)} · '
            '${sourceAppLabel(s.sourceApp)}',
          ),
          sportType: sport,
          startAt: s.start.toUtc(),
          localDate: LocalDates.key(s.start),
          distanceM: Value(distance),
          // Health Connect sessions have no moving time; only elapsed.
          elapsedTimeS: Value(seconds),
          avgHeartRate: Value(avgHr),
          maxHeartRate: Value(maxHr),
          avgSpeedMps: Value(
            distance != null && seconds > 0 ? distance / seconds : null,
          ),
          calories: Value(
            (s.totalEnergyKcal ?? 0) > 0 ? s.totalEnergyKcal : null,
          ),
          rawJson: Value(
            jsonEncode({
              'workout_type': s.workoutType,
              'source_app': s.sourceApp,
              'calories_kind': 'total_calories_burned',
              'steps': s.totalSteps,
              'distance_m': s.totalDistanceM,
            }),
          ),
          updatedAt: Value(_clock.now().toUtc()),
          fetchedAt: Value(_clock.now().toUtc()),
        ),
      );
    }
  }

  Future<void> _syncSleep(
    String startDate,
    String today,
    DateTime windowStart,
    DateTime now,
  ) async {
    // Sessions ending on the first day of the window may start the day
    // before.
    final readStart = windowStart.subtract(const Duration(hours: 24));
    final sessions = dedupeByUuid(
      await _ds.read(HcDataType.sleepSession, readStart, now),
    ).where((s) => s.uuid.isNotEmpty && s.end.isAfter(s.start)).toList();

    await _repo.replaceSamples(
      type: HealthKeys.sleepSession,
      windowStart: readStart,
      rows: [
        for (final s in sessions)
          _repo.hcSample(
            type: HealthKeys.sleepSession,
            externalId: s.uuid,
            value: s.duration.inMinutes.toDouble(),
            unit: 'min',
            start: s.start,
            end: s.end,
            localDate: sleepNightDate(s.end),
            sourceApp: s.sourceApp,
            sourceDevice: deviceTypeFromMetadata(s.metadata),
          ),
      ],
    );
    final nights = sleepMinutesPerNight(sessions);
    await _repo.replaceDailySummaries(
      type: HealthKeys.sleepMinutes,
      unit: 'min',
      startDate: startDate,
      endDate: today,
      values: {
        for (final n in nights.values)
          if (n.localDate.compareTo(startDate) >= 0 &&
              n.localDate.compareTo(today) <= 0)
            n.localDate: (value: n.value, sources: n.sourcesSummary),
      },
    );
  }

  Future<void> _syncHeartRate(DateTime now) async {
    final windowStart = now.subtract(heartRateWindow);
    final samples = await _ds.read(HcDataType.heartRate, windowStart, now);
    final kept = downsampleHeartRate(
      samples.where((s) => !s.start.isBefore(windowStart)),
    );
    await _repo.replaceSamples(
      type: HealthKeys.heartRate,
      windowStart: windowStart,
      rows: [
        for (final b in kept)
          _repo.hcSample(
            type: HealthKeys.heartRate,
            externalId: 'hr:${b.bucketStart.millisecondsSinceEpoch}',
            value: b.sample.value,
            unit: 'bpm',
            start: b.sample.start,
            end: b.sample.start,
            sourceApp: b.sample.sourceApp,
            sourceDevice: deviceTypeFromMetadata(b.sample.metadata),
            metadata: {
              'hc_uuid': b.sample.uuid,
              'bucket_minutes': 5,
              'bucket_count': b.count,
              'bucket_min': b.min,
              'bucket_max': b.max,
            },
          ),
      ],
    );
  }

  Future<void> _syncInstants(
    HcDataType type,
    String key,
    String unit,
    DateTime windowStart,
    DateTime now,
  ) async {
    final records = dedupeByUuid(await _ds.read(type, windowStart, now))
        .where((r) => r.uuid.isNotEmpty)
        .toList();
    await _repo.replaceSamples(
      type: key,
      windowStart: windowStart,
      rows: [
        for (final r in records)
          _repo.hcSample(
            type: key,
            externalId: r.uuid,
            value: r.value,
            unit: unit,
            start: r.start,
            end: r.end,
            sourceApp: r.sourceApp,
            sourceDevice: deviceTypeFromMetadata(r.metadata),
            metadata: {
              if (r.recordingMethod != null)
                'recording_method': r.recordingMethod,
            },
          ),
      ],
    );
  }
}
