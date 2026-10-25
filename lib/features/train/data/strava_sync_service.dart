// Strava activity sync with Strava API Policy compliance:
// * §6.2 cache ≤ 7 days — rows are re-fetched before they turn 7 days old,
//   anything older is purged (also on every app start);
// * activities deleted on Strava disappear on the next sync of their window;
// * deauthorization deletes every Strava row immediately;
// * streams are fetched on demand and never persisted;
// * Strava data is never sent to any AI (§5.3) — nothing here touches AI.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../integrations/data/api_errors.dart';
import '../domain/running_models.dart';
import 'cardio_repository.dart';
import 'strava_api_client.dart';
import 'strava_auth.dart';

const kStravaInitialWindow = Duration(days: 90);
const kStravaCacheMaxAge = Duration(days: 7);

/// Refresh rows a day before they hit the 7-day limit.
const kStravaRefreshAge = Duration(days: 6);

String stravaLocalId(String stravaId) => stableId('strava', stravaId);

String? _tzName(Object? raw) {
  final s = raw?.toString();
  if (s == null || s.isEmpty) return null;
  final i = s.indexOf(') ');
  return i >= 0 ? s.substring(i + 2) : s;
}

/// Maps a Strava SummaryActivity/DetailedActivity to a DB row.
CardioActivitiesCompanion mapStravaActivity(
  Map<String, dynamic> a, {
  required DateTime fetchedAt,
}) {
  final id = a['id'].toString();
  final start =
      DateTime.tryParse(a['start_date']?.toString() ?? '')?.toUtc() ??
      fetchedAt.toUtc();
  // start_date_local is the athlete's wall-clock time (marked "Z" by Strava).
  final localRaw = a['start_date_local']?.toString();
  final localDate = localRaw != null && localRaw.length >= 10
      ? localRaw.substring(0, 10)
      : LocalDates.key(start);
  double? d(String k) => (a[k] as num?)?.toDouble();
  int? i(String k) => (a[k] as num?)?.round();
  final splits = splitsFromStrava(a['splits_metric']);
  final laps = lapsFromStrava(a['laps']);
  return CardioActivitiesCompanion.insert(
    id: stravaLocalId(id),
    source: 'strava',
    externalId: Value(id),
    name: Value(a['name']?.toString()),
    sportType: SportTypes.fromStrava(
      a['sport_type']?.toString() ?? a['type']?.toString(),
    ),
    startAt: start,
    localDate: localDate,
    tzName: Value(_tzName(a['timezone'])),
    distanceM: Value(d('distance')),
    movingTimeS: Value(i('moving_time')),
    elapsedTimeS: Value(i('elapsed_time')),
    elevationGainM: Value(d('total_elevation_gain')),
    avgHeartRate: Value(d('average_heartrate')),
    maxHeartRate: Value(d('max_heartrate')),
    avgSpeedMps: Value(d('average_speed')),
    calories: Value(d('calories')),
    splitsJson: Value(splits == null ? null : RunSplit.listToJson(splits)),
    lapsJson: Value(laps == null ? null : jsonEncode(laps)),
    fetchedAt: Value(fetchedAt.toUtc()),
    updatedAt: Value(fetchedAt.toUtc()),
  );
}

List<RunSplit>? splitsFromStrava(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final s in raw.whereType<Map>())
      RunSplit(
        distanceM: (s['distance'] as num?)?.toDouble() ?? 0,
        movingTimeS: (s['moving_time'] as num?)?.round() ?? 0,
        elapsedTimeS: (s['elapsed_time'] as num?)?.round(),
        avgHr: (s['average_heartrate'] as num?)?.toDouble(),
        elevDiffM: (s['elevation_difference'] as num?)?.toDouble(),
      ),
  ];
}

List<Map<String, Object?>>? lapsFromStrava(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final l in raw.whereType<Map>())
      {
        'name': l['name']?.toString(),
        'distance_m': (l['distance'] as num?)?.toDouble(),
        'moving_time_s': (l['moving_time'] as num?)?.round(),
        'elapsed_time_s': (l['elapsed_time'] as num?)?.round(),
        'avg_hr': (l['average_heartrate'] as num?)?.toDouble(),
        'avg_speed_mps': (l['average_speed'] as num?)?.toDouble(),
      },
  ];
}

class StravaSyncResult {
  const StravaSyncResult({
    required this.upserted,
    required this.removed,
    required this.purged,
  });
  final int upserted;

  /// Rows deleted because they no longer exist on Strava.
  final int removed;

  /// Rows purged by the 7-day cache rule / 90-day window.
  final int purged;
}

class StravaSyncService {
  StravaSyncService({
    required this._db,
    required this._cardio,
    required this._api,
    required this._status,
    required this._clock,
  });

  final AppDatabase _db;
  final CardioRepository _cardio;
  final StravaApi _api;
  final IntegrationStatusRepository _status;
  final Clock _clock;

  /// §6.2 enforcement without network: delete rows older than 7 days.
  Future<int> enforceCacheRule() =>
      _cardio.purgeStaleStrava(_clock.now(), maxAge: kStravaCacheMaxAge);

  Future<StravaSyncResult> sync({int detailForLatestRuns = 10}) async {
    final now = _clock.now().toUtc();
    final windowStart = now.subtract(kStravaInitialWindow);
    try {
      // Drop rows outside the window (they'd otherwise go stale).
      var purged =
          await (_db.delete(_db.cardioActivities)..where(
                (c) =>
                    c.source.equals('strava') &
                    c.startAt.isSmallerThanValue(windowStart),
              ))
              .go();

      final rows = await _cardio.sourceRows('strava');
      DateTime? oldestStale;
      for (final r in rows) {
        if (now.difference(r.fetchedAt) >= kStravaRefreshAge &&
            (oldestStale == null || r.startAt.isBefore(oldestStale))) {
          oldestStale = r.startAt;
        }
      }
      final row = await _status.get('strava');
      final cursorSecs = int.tryParse(row?.cursor ?? '');
      DateTime after;
      if (cursorSecs == null || rows.isEmpty) {
        after = windowStart;
      } else {
        after = DateTime.fromMillisecondsSinceEpoch(
          cursorSecs * 1000,
          isUtc: true,
        ).subtract(const Duration(days: 1));
        if (oldestStale != null && oldestStale.isBefore(after)) {
          after = oldestStale;
        }
      }
      if (after.isBefore(windowStart)) after = windowStart;
      after = after.subtract(const Duration(seconds: 1));

      final seen = <String>{};
      var newest = cursorSecs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(cursorSecs * 1000, isUtc: true);
      var upserted = 0;
      for (var page = 1; page <= 50; page++) {
        final items = await _api.listActivities(
          after: after,
          page: page,
          perPage: 100,
        );
        for (final a in items) {
          if (a['id'] == null) continue;
          final c = mapStravaActivity(a, fetchedAt: now);
          seen.add(c.id.value);
          // Summaries carry no splits; keep fresh detail if we have it.
          await _cardio.upsertStravaSummary(
            c.copyWith(
              splitsJson: const Value.absent(),
              lapsJson: const Value.absent(),
            ),
            now: now,
          );
          if (newest == null || c.startAt.value.isAfter(newest)) {
            newest = c.startAt.value;
          }
          upserted++;
        }
        if (items.length < 100) break;
      }

      // Reflect deletions on Strava within the re-listed range.
      final missing = [
        for (final r in await _cardio.sourceRows('strava'))
          if (!r.startAt.isBefore(after) && !seen.contains(r.id)) r.id,
      ];
      final removed = await _cardio.deleteIds(missing);

      // Lazily fetch splits for the latest runs that lack them.
      if (detailForLatestRuns > 0) {
        final runs =
            (await _cardio.sourceRows('strava'))
                .where((r) => r.sportType == SportTypes.run)
                .toList()
              ..sort((a, b) => b.startAt.compareTo(a.startAt));
        for (final r in runs.take(detailForLatestRuns)) {
          if (r.splitsJson != null) continue;
          try {
            await fetchDetail(r.id);
          } on RateLimitedException {
            break;
          } on ApiException {
            continue;
          }
        }
      }

      purged += await enforceCacheRule();
      await _status.recordSync(
        'strava',
        cursor: newest == null
            ? null
            : '${newest.millisecondsSinceEpoch ~/ 1000}',
      );
      return StravaSyncResult(
        upserted: upserted,
        removed: removed,
        purged: purged,
      );
    } on InvalidCredentialsException catch (e) {
      await _status.setStatus(
        'strava',
        ConnectionStates.error,
        error: e.message,
      );
      rethrow;
    } on IntegrationException catch (e) {
      await enforceCacheRule();
      await _status.recordSync('strava', error: e.message);
      rethrow;
    }
  }

  /// Fetches DetailedActivity (splits_metric, laps) for a local row.
  Future<void> fetchDetail(String localId) async {
    final row = await _cardio.getRow(localId);
    if (row == null || row.source != 'strava' || row.externalId == null) return;
    try {
      final a = await _api.activity(row.externalId!);
      final splits = splitsFromStrava(a['splits_metric']);
      final laps = lapsFromStrava(a['laps']);
      await _cardio.updateStravaDetail(
        localId,
        splitsJson: splits == null ? null : RunSplit.listToJson(splits),
        lapsJson: laps == null ? null : jsonEncode(laps),
        fetchedAt: _clock.now(),
        maxHr: (a['max_heartrate'] as num?)?.toDouble(),
        calories: (a['calories'] as num?)?.toDouble(),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // Deleted on Strava.
        await _cardio.deleteIds([localId]);
        return;
      }
      rethrow;
    }
  }

  /// On-demand streams for charts. Never persisted.
  Future<Map<String, List<double>>> streams(String localId) async {
    final row = await _cardio.getRow(localId);
    if (row == null || row.source != 'strava' || row.externalId == null) {
      return const {};
    }
    return _api.streams(row.externalId!);
  }

  /// Deauthorization: every Strava row is deleted immediately.
  Future<void> deleteAllStravaData() async {
    await _cardio.deleteSource('strava');
    await (_db.update(_db.integrationConnections)
          ..where((c) => c.provider.equals('strava')))
        .write(const IntegrationConnectionsCompanion(cursor: Value(null)));
  }
}

final stravaApiProvider = Provider<StravaApi>((ref) {
  final auth = ref.watch(stravaAuthServiceProvider);
  return HttpStravaApi(
    token: ({bool forceRefresh = false}) =>
        auth.accessToken(forceRefresh: forceRefresh),
  );
});

final stravaSyncServiceProvider = Provider<StravaSyncService>(
  (ref) => StravaSyncService(
    db: ref.watch(databaseProvider),
    cardio: ref.watch(cardioRepositoryProvider),
    api: ref.watch(stravaApiProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Disconnect: revoke on the backend, wipe the local token and all data.
Future<void> disconnectStrava({
  required StravaAuthService auth,
  required StravaSyncService sync,
  required IntegrationStatusRepository status,
}) async {
  // Data first, so nothing lingers even if the revoke call fails.
  await sync.deleteAllStravaData();
  await auth.revokeAndClear();
  await status.setStatus(
    'strava',
    ConnectionStates.disconnected,
    scopes: const [],
    clearError: true,
  );
}
