import 'dart:convert';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/features/integrations/data/api_errors.dart';
import 'package:athlete_os/features/integrations/data/secret_store.dart';
import 'package:athlete_os/features/train/data/cardio_repository.dart';
import 'package:athlete_os/features/train/data/strava_api_client.dart';
import 'package:athlete_os/features/train/data/strava_auth.dart';
import 'package:athlete_os/features/train/data/strava_sync_service.dart';
import 'package:athlete_os/features/train/domain/running_analytics.dart';
import 'package:athlete_os/features/train/domain/running_models.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/test_app.dart';

Map<String, dynamic> stravaActivity(
  int id,
  DateTime start, {
  String sport = 'Run',
  double distance = 5000,
}) => {
  'id': id,
  'name': 'Morning Run',
  'sport_type': sport,
  'type': sport,
  'start_date': start.toUtc().toIso8601String(),
  'start_date_local': '${start.toIso8601String().substring(0, 19)}Z',
  'timezone': '(GMT+05:30) Asia/Kolkata',
  'distance': distance,
  'moving_time': 1500,
  'elapsed_time': 1600,
  'total_elevation_gain': 12.5,
  'average_heartrate': 155.2,
  'max_heartrate': 171.0,
  'average_speed': 3.33,
};

class FakeStravaApi implements StravaApi {
  List<Map<String, dynamic>> activities = [];
  Map<String, Map<String, dynamic>> details = {};
  final listAfter = <DateTime?>[];
  int detailCalls = 0;

  @override
  final StravaRateLimit rateLimit = StravaRateLimit();

  @override
  Future<List<Map<String, dynamic>>> listActivities({
    DateTime? after,
    DateTime? before,
    int page = 1,
    int perPage = 100,
  }) async {
    listAfter.add(after);
    if (page > 1) return [];
    return activities
        .where(
          (a) =>
              after == null ||
              DateTime.parse(a['start_date'] as String).isAfter(after),
        )
        .toList();
  }

  @override
  Future<Map<String, dynamic>> activity(String id) async {
    detailCalls++;
    final d = details[id];
    if (d == null) throw ApiException(404, 'not found');
    return d;
  }

  @override
  Future<Map<String, List<double>>> streams(String id) async => {};
}

void main() {
  late AppDatabase db;
  late FakeStravaApi api;
  late CardioRepository cardio;
  late IntegrationStatusRepository status;
  var now = DateTime.utc(2026, 10, 25, 9);

  StravaSyncService service() => StravaSyncService(
    db: db,
    cardio: cardio,
    api: api,
    status: status,
    clock: FixedClock(now),
  );

  setUp(() async {
    db = newTestDb();
    api = FakeStravaApi();
    cardio = CardioRepository(db);
    status = IntegrationStatusRepository(db);
    now = DateTime.utc(2026, 10, 25, 9);
    await status.setStatus(Providers.strava, ConnectionStates.connected);
  });
  tearDown(() => db.close());

  test('maps Strava activities with normalised sport types', () {
    final c = mapStravaActivity({
      ...stravaActivity(42, DateTime(2026, 10, 20, 6, 30)),
      'splits_metric': [
        {
          'distance': 1000.0,
          'moving_time': 300,
          'elapsed_time': 305,
          'average_heartrate': 150.0,
          'elevation_difference': 2.0,
        },
      ],
    }, fetchedAt: now);
    expect(c.source.value, 'strava');
    expect(c.externalId.value, '42');
    expect(c.id.value, stravaLocalId('42'));
    expect(c.sportType.value, 'run');
    expect(c.localDate.value, '2026-10-20');
    expect(c.tzName.value, 'Asia/Kolkata');
    expect(c.distanceM.value, 5000);
    expect(c.fetchedAt.value, now);
    final splits = RunSplit.listFromJson(c.splitsJson.value);
    expect(splits.single.distanceM, 1000);
    expect(splits.single.avgHr, 150);
    expect(splits.single.elevDiffM, 2);
    for (final (raw, exp) in [
      ('TrailRun', 'run'),
      ('VirtualRun', 'run'),
      ('Walk', 'walk'),
      ('Hike', 'hike'),
      ('Ride', 'ride'),
      ('Swim', 'other'),
    ]) {
      expect(SportTypes.fromStrava(raw), exp);
    }
  });

  test('initial sync covers 90 days, fetches latest run details', () async {
    api.activities = [
      stravaActivity(1, now.subtract(const Duration(days: 2))),
      stravaActivity(2, now.subtract(const Duration(days: 5)), sport: 'Ride'),
    ];
    api.details['1'] = {
      ...api.activities.first,
      'splits_metric': [
        {'distance': 1000.0, 'moving_time': 300},
      ],
      'laps': [
        {'name': 'Lap 1', 'distance': 5000.0, 'moving_time': 1500},
      ],
    };
    final r = await service().sync();
    expect(r.upserted, 2);
    expect(
      api.listAfter.first!.isBefore(now.subtract(const Duration(days: 89))),
      isTrue,
    );
    final rows = await cardio.sourceRows('strava');
    expect(rows, hasLength(2));
    final runRow = rows.firstWhere((x) => x.externalId == '1');
    expect(runRow.splitsJson, isNotNull);
    expect(runRow.lapsJson, contains('Lap 1'));
    expect(api.detailCalls, 1); // the ride gets no detail call
    expect((await status.get(Providers.strava))!.cursor, isNotNull);
  });

  test('activities deleted on Strava are removed on re-sync', () async {
    api.activities = [
      stravaActivity(1, now.subtract(const Duration(days: 2))),
      stravaActivity(2, now.subtract(const Duration(days: 1))),
    ];
    await service().sync(detailForLatestRuns: 0);
    api.activities.removeAt(0);
    final r = await service().sync(detailForLatestRuns: 0);
    expect(r.removed, 1);
    final ids = (await cardio.sourceRows('strava')).map((x) => x.externalId);
    expect(ids, ['2']);
  });

  test('7-day cache rule: stale rows are refreshed or purged', () async {
    api.activities = [
      stravaActivity(1, now.subtract(const Duration(days: 20))),
      stravaActivity(2, now.subtract(const Duration(days: 3))),
    ];
    await service().sync(detailForLatestRuns: 0);

    // 8 days later without any sync → purge on start leaves nothing.
    now = now.add(const Duration(days: 8));
    final purged = await service().enforceCacheRule();
    expect(purged, 2);
    expect(await cardio.countSource('strava'), 0);
  });

  test('re-sync re-fetches rows nearing 7 days (refresh, not purge)', () async {
    api.activities = [
      stravaActivity(1, now.subtract(const Duration(days: 30))),
    ];
    await service().sync(detailForLatestRuns: 0);
    now = now.add(const Duration(days: 6, hours: 12));
    api.listAfter.clear();
    await service().sync(detailForLatestRuns: 0);
    // The listing window went back to the oldest stale row.
    expect(
      api.listAfter.single!.isBefore(now.subtract(const Duration(days: 36))),
      isTrue,
    );
    final row = (await cardio.sourceRows('strava')).single;
    expect(row.fetchedAt.isAtSameMomentAs(now), isTrue);
  });

  test(
    'stale detail (splits) is dropped when the summary is refreshed',
    () async {
      api.activities = [
        stravaActivity(1, now.subtract(const Duration(days: 1))),
      ];
      api.details['1'] = {
        ...api.activities.first,
        'splits_metric': [
          {'distance': 1000.0, 'moving_time': 300},
        ],
      };
      await service().sync();
      now = now.add(const Duration(days: 8));
      api.details.clear();
      await service().sync(detailForLatestRuns: 0);
      final row = (await cardio.sourceRows('strava')).single;
      expect(row.splitsJson, isNull);
    },
  );

  test(
    'deauthorization deletes every Strava row but not other sources',
    () async {
      api.activities = [
        stravaActivity(1, now.subtract(const Duration(days: 1))),
      ];
      await service().sync(detailForLatestRuns: 0);
      await db
          .into(db.cardioActivities)
          .insert(
            CardioActivitiesCompanion.insert(
              id: 'hc1',
              source: 'health_connect',
              sportType: 'run',
              startAt: now.subtract(const Duration(days: 1)),
              localDate: '2026-10-24',
              distanceM: const Value(5000),
            ),
          );
      final secrets = InMemorySecretStore({
        SecretKeys.stravaAccessToken: 'tok',
        SecretKeys.stravaExpiresAt: '9999999999',
      });
      final auth = StravaAuthService(
        secrets: secrets,
        backend: _FakeBackend(),
        status: status,
        clock: FixedClock(now),
        configured: true,
        clientId: '123',
      );
      await disconnectStrava(auth: auth, sync: service(), status: status);
      expect(await cardio.countSource('strava'), 0);
      expect(await cardio.countSource('health_connect'), 1);
      expect(await secrets.read(SecretKeys.stravaAccessToken), isNull);
      expect(
        (await status.get(Providers.strava))!.status,
        ConnectionStates.disconnected,
      );
    },
  );

  test('dedupe with Health Connect rows from the database', () async {
    final start = now.subtract(const Duration(days: 1));
    api.activities = [stravaActivity(1, start)];
    await service().sync(detailForLatestRuns: 0);
    await db
        .into(db.cardioActivities)
        .insert(
          CardioActivitiesCompanion.insert(
            id: 'hc1',
            source: 'health_connect',
            sportType: 'run',
            startAt: start.add(const Duration(minutes: 1)),
            localDate: '2026-10-24',
            distanceM: const Value(5100),
            movingTimeS: const Value(1520),
          ),
        );
    final shown = dedupeActivities(await cardio.all());
    expect(shown, hasLength(1));
    expect(shown.single.isStrava, isTrue);
    expect(shown.single.alsoInHealthConnect, isTrue);
  });

  group('HttpStravaApi', () {
    test('tracks rate-limit headers and backs off near the limit', () async {
      final client = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer tok');
        return http.Response(
          jsonEncode([stravaActivity(1, DateTime.utc(2026, 10, 24))]),
          200,
          headers: {
            'x-ratelimit-limit': '200,2000',
            'x-ratelimit-usage': '20,300',
            'x-readratelimit-limit': '100,1000',
            'x-readratelimit-usage': '95,500',
          },
        );
      });
      final t = DateTime.utc(2026, 10, 25, 9, 7);
      final api = HttpStravaApi(
        token: ({bool forceRefresh = false}) async => 'tok',
        client: client,
        now: () => t,
      );
      final list = await api.listActivities(after: DateTime.utc(2026, 10, 1));
      expect(list, hasLength(1));
      expect(api.rateLimit.readUsage15, 95);
      expect(api.rateLimit.readLimit15, 100);
      // 95/100 ≥ 90% → wait until the next 15-minute window (09:15).
      expect(api.rateLimit.backoff(t), const Duration(minutes: 8));
      await expectLater(
        api.listActivities(),
        throwsA(isA<RateLimitedException>()),
      );
    });

    test('401 triggers one token refresh then succeeds', () async {
      var refreshed = false;
      final client = MockClient((req) async {
        if (req.headers['Authorization'] == 'Bearer old') {
          return http.Response('', 401);
        }
        return http.Response('[]', 200);
      });
      final api = HttpStravaApi(
        token: ({bool forceRefresh = false}) async {
          if (forceRefresh) refreshed = true;
          return forceRefresh ? 'new' : 'old';
        },
        client: client,
      );
      expect(await api.listActivities(), isEmpty);
      expect(refreshed, isTrue);
    });

    test('429 is surfaced as rate limited without hammering', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('', 429);
      });
      final api = HttpStravaApi(
        token: ({bool forceRefresh = false}) async => 'tok',
        client: client,
      );
      await expectLater(
        api.listActivities(),
        throwsA(isA<RateLimitedException>()),
      );
      expect(calls, 1);
    });
  });

  group('StravaAuthService', () {
    test('authorize URL has required params and scopes', () {
      final auth = StravaAuthService(
        secrets: InMemorySecretStore(),
        backend: _FakeBackend(),
        status: status,
        clock: FixedClock(now),
        configured: true,
        clientId: '123',
      );
      final u = auth.authorizeUri('abc');
      expect(u.host, 'www.strava.com');
      expect(u.path, '/oauth/mobile/authorize');
      expect(u.queryParameters['redirect_uri'], 'athleteos://localhost/strava');
      expect(u.queryParameters['scope'], 'read,activity:read_all');
      expect(u.queryParameters['approval_prompt'], 'auto');
      expect(u.queryParameters['state'], 'abc');
    });

    test('rejects a callback with a mismatched state', () async {
      final auth = StravaAuthService(
        secrets: InMemorySecretStore(),
        backend: _FakeBackend(),
        status: status,
        clock: FixedClock(now),
        configured: true,
        clientId: '123',
        launcher: ({required url, required callbackUrlScheme}) async => 'athleteos://localhost/strava?state=evil&code=x&scope=read,activity:read_all',
      );
      await expectLater(auth.connect(), throwsA(isA<ApiException>()));
    });

    test('connect stores token and marks connected after exchange', () async {
      final secrets = InMemorySecretStore();
      final auth = StravaAuthService(
        secrets: secrets,
        backend: _FakeBackend(),
        status: status,
        clock: FixedClock(now),
        configured: true,
        clientId: '123',
        launcher: ({required url, required callbackUrlScheme}) async {
          expect(callbackUrlScheme, 'athleteos');
          final state = Uri.parse(url).queryParameters['state'];
          return 'athleteos://localhost/strava?state=$state&code=c0de'
              '&scope=read,activity:read_all';
        },
      );
      await auth.connect();
      expect(await secrets.read(SecretKeys.stravaAccessToken), 'access-1');
      final row = await status.get(Providers.strava);
      expect(row!.status, ConnectionStates.connected);
      expect(row.scopesJson, contains('activity:read_all'));
    });

    test(
      'not configured → awaiting credentials, no browser launched',
      () async {
        var launched = false;
        final auth = StravaAuthService(
          secrets: InMemorySecretStore(),
          backend: _FakeBackend(),
          status: status,
          clock: FixedClock(now),
          configured: false,
          launcher: ({required url, required callbackUrlScheme}) async {
            launched = true;
            return '';
          },
        );
        await expectLater(
          auth.connect(),
          throwsA(isA<AwaitingCredentialsException>()),
        );
        expect(launched, isFalse);
      },
    );
  });
}

class _FakeBackend implements StravaBackend {
  @override
  Future<StravaTokenGrant> exchange({
    required String code,
    required String redirectUri,
    String? scope,
  }) async => StravaTokenGrant(
    accessToken: 'access-1',
    expiresAt: DateTime.utc(2030),
    athleteId: 7,
    scope: scope,
  );

  @override
  Future<StravaTokenGrant> refresh() async =>
      StravaTokenGrant(accessToken: 'access-2', expiresAt: DateTime.utc(2030));

  @override
  Future<void> revoke() async {}
}
