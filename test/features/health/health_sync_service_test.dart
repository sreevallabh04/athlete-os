import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/health/application/health_permissions.dart';
import 'package:athlete_os/features/health/application/health_sync_service.dart';
import 'package:athlete_os/features/health/data/fake_health_data_source.dart';
import 'package:athlete_os/features/health/data/health_repository.dart';
import 'package:athlete_os/features/health/data/health_settings.dart';
import 'package:athlete_os/features/health/domain/health_types.dart';
import 'package:athlete_os/features/health/domain/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

HcRecord rec(
  HcDataType type,
  DateTime start,
  DateTime end, {
  required String uuid,
  double value = 0,
  String source = samsungHealthPackage,
  String? workoutType,
  double? distance,
  double? kcal,
}) => HcRecord(
  uuid: uuid,
  type: type,
  value: value,
  unit: 'X',
  start: start.toUtc(),
  end: end.toUtc(),
  sourceApp: source,
  workoutType: workoutType,
  totalDistanceM: distance,
  totalEnergyKcal: kcal,
);

class Harness {
  Harness(this.db, this.fake, this.now)
    : clock = FixedClock(now),
      status = IntegrationStatusRepository(db),
      settings = HealthSettings(SettingsRepository(db)) {
    repo = HealthRepository(db, clock);
    service = HealthSyncService(
      source: fake,
      repository: repo,
      status: status,
      settings: settings,
      clock: clock,
    );
  }

  final AppDatabase db;
  final FakeHealthDataSource fake;
  final DateTime now;
  final FixedClock clock;
  final IntegrationStatusRepository status;
  final HealthSettings settings;
  late final HealthRepository repo;
  late final HealthSyncService service;

  Future<Map<String, int>> counts() async => {
    'summaries': (await db.select(db.dailyHealthSummaries).get()).length,
    'samples': (await db.select(db.healthSamples).get()).length,
    'cardio': (await db.select(db.cardioActivities).get()).length,
  };
}

List<HcRecord> sampleData(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  return [
    // Steps: today 5,400 (two apps), yesterday 8,000.
    rec(
      HcDataType.steps,
      today.add(const Duration(hours: 8)),
      today.add(const Duration(hours: 9)),
      uuid: 'st1',
      value: 3000,
    ),
    rec(
      HcDataType.steps,
      today.add(const Duration(hours: 12)),
      today.add(const Duration(hours: 13)),
      uuid: 'st2',
      value: 2400,
      source: googleFitPackage,
    ),
    rec(
      HcDataType.steps,
      yesterday.add(const Duration(hours: 10)),
      yesterday.add(const Duration(hours: 11)),
      uuid: 'st3',
      value: 8000,
    ),
    // Distance from two apps covering the same walk.
    rec(
      HcDataType.distance,
      today.add(const Duration(hours: 8)),
      today.add(const Duration(hours: 9)),
      uuid: 'd1',
      value: 2500,
    ),
    rec(
      HcDataType.distance,
      today.add(const Duration(hours: 8)),
      today.add(const Duration(hours: 9)),
      uuid: 'd2',
      value: 2300,
      source: googleFitPackage,
    ),
    rec(
      HcDataType.activeCalories,
      today.add(const Duration(hours: 8)),
      today.add(const Duration(hours: 9)),
      uuid: 'ac1',
      value: 210,
    ),
    // A morning run (cardio) and a strength session (not cardio).
    rec(
      HcDataType.exercise,
      today.add(const Duration(hours: 7)),
      today.add(const Duration(hours: 7, minutes: 30)),
      uuid: 'run-1',
      workoutType: 'RUNNING',
      distance: 5000,
      kcal: 350,
    ),
    rec(
      HcDataType.exercise,
      yesterday.add(const Duration(hours: 18)),
      yesterday.add(const Duration(hours: 19)),
      uuid: 'lift-1',
      workoutType: 'STRENGTH_TRAINING',
    ),
    // Sleep crossing midnight into today.
    rec(
      HcDataType.sleepSession,
      yesterday.add(const Duration(hours: 23, minutes: 30)),
      today.add(const Duration(hours: 7)),
      uuid: 'sleep-1',
      value: 450,
    ),
    // Heart rate: one reading per minute during the run.
    for (var i = 0; i < 30; i++)
      rec(
        HcDataType.heartRate,
        today.add(Duration(hours: 7, minutes: i)),
        today.add(Duration(hours: 7, minutes: i)),
        uuid: 'hr-series',
        value: 140.0 + i % 5,
      ),
    rec(
      HcDataType.restingHeartRate,
      today.add(const Duration(hours: 6)),
      today.add(const Duration(hours: 6)),
      uuid: 'rhr-1',
      value: 52,
    ),
    rec(
      HcDataType.weight,
      today.add(const Duration(hours: 6, minutes: 30)),
      today.add(const Duration(hours: 6, minutes: 30)),
      uuid: 'w-1',
      value: 78.4,
    ),
  ];
}

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 10, 25, 15);
  final today = LocalDates.key(now);
  final yesterday = LocalDates.addDays(today, -1);

  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  Future<Harness> connected() async {
    final h = Harness(
      db,
      FakeHealthDataSource(
        granted: HcDataType.values.toSet(),
        records: sampleData(now),
      ),
      now,
    );
    for (final g in HealthGroup.values) {
      await h.settings.setGroupEnabled(g, true);
    }
    return h;
  }

  test('sync imports every permitted type with correct values', () async {
    final h = await connected();
    final result = await h.service.sync();
    expect(result.outcome, SyncOutcome.ok, reason: result.warnings.join());
    expect(result.windowDays, 30);

    final steps = await h.repo.summaries(HealthKeys.steps, today, today);
    expect(steps.single.value, 5400);
    expect(steps.single.origin, 'health_connect');
    expect(steps.single.sourcesSummary, 'Google Fit, Samsung Health');
    expect((await h.repo.stepsForDay(yesterday))!.steps, 8000);

    final distance = await h.repo.summaries(HealthKeys.distance, today, today);
    expect(distance.single.value, 2500); // one source per day, not 4800
    final sleep = await h.repo.summaries(HealthKeys.sleepMinutes, today, today);
    expect(sleep.single.value, 450);
    final active = await h.repo.summaries(
      HealthKeys.activeMinutes,
      yesterday,
      today,
    );
    expect(
      {for (final a in active) a.localDate: a.value},
      {yesterday: 60, today: 30},
    );

    expect(await h.repo.countSamples(HealthKeys.heartRate), 6);
    expect(await h.repo.countSamples(HealthKeys.exerciseSession), 2);
    expect(await h.repo.countSamples(HealthKeys.weight), 1);

    final cardio = await db.select(db.cardioActivities).get();
    expect(cardio, hasLength(1));
    expect(cardio.single.source, 'health_connect');
    expect(cardio.single.externalId, 'run-1');
    expect(cardio.single.sportType, 'run');
    expect(cardio.single.distanceM, 5000);
    expect(cardio.single.elapsedTimeS, 1800);
    expect(cardio.single.avgHeartRate, closeTo(142, 0.01));

    final conn = await h.status.get(Providers.healthConnect);
    expect(conn!.status, ConnectionStates.connected);
    expect(conn.lastSyncAt, isNotNull);
    expect(conn.lastError, isNull);
  });

  test('running sync twice is idempotent (same row counts)', () async {
    final h = await connected();
    await h.service.sync();
    final first = await h.counts();
    final second = await h.service.sync();
    expect(second.outcome, SyncOutcome.ok);
    expect(second.windowDays, 7, reason: 'incremental after first sync');
    expect(await h.counts(), first);
    await h.service.sync(days: 30);
    expect(await h.counts(), first);
  });

  test('concurrent sync calls share one run', () async {
    final h = await connected();
    final a = h.service.sync();
    final b = h.service.sync();
    expect(h.service.isSyncing, isTrue);
    await Future.wait([a, b]);
    final readsForTwo = h.fake.readCalls;
    expect(h.service.isSyncing, isFalse);

    h.fake.readCalls = 0;
    await h.service.sync(days: 30);
    expect(readsForTwo, h.fake.readCalls);
  });

  test('revoked permission is detected and recorded', () async {
    final h = await connected();
    await h.service.sync();
    expect(
      (await h.status.get(Providers.healthConnect))!.status,
      ConnectionStates.connected,
    );

    h.fake.granted.clear(); // user revoked everything in Health Connect
    final result = await h.service.sync();
    expect(result.outcome, SyncOutcome.notPermitted);
    final conn = await h.status.get(Providers.healthConnect);
    expect(conn!.status, ConnectionStates.needsSetup);
    expect(conn.lastError, contains('revoked'));
    // Previously synced data is kept (and labelled with its sync time).
    expect((await h.repo.stepsForDay(today))!.steps, 5400);
  });

  test(
    'partially revoked permission syncs the rest and lists denied',
    () async {
      final h = await connected();
      h.fake.granted.remove(HcDataType.heartRate);
      final result = await h.service.sync();
      expect(result.outcome, SyncOutcome.ok);
      expect(result.denied, contains(HcDataType.heartRate));
      expect(await h.repo.countSamples(HealthKeys.heartRate), 0);
      final cardio = await db.select(db.cardioActivities).getSingle();
      expect(cardio.avgHeartRate, isNull);
    },
  );

  test('a failing type is reported as partial, others still import', () async {
    final h = await connected();
    h.fake.failingTypes.add(HcDataType.sleepSession);
    final result = await h.service.sync();
    expect(result.outcome, SyncOutcome.partial);
    expect(result.warnings.single, startsWith('sleep'));
    expect((await h.repo.stepsForDay(today))!.steps, 5400);
  });

  test('unavailable Health Connect → needs setup, nothing read', () async {
    final h = await connected();
    h.fake.status = HcSdkStatus.needsInstall;
    final result = await h.service.sync();
    expect(result.outcome, SyncOutcome.unavailable);
    expect(h.fake.readCalls, 0);
    final conn = await h.status.get(Providers.healthConnect);
    expect(conn!.status, ConnectionStates.needsSetup);
  });

  test('no enabled groups → not enabled, no reads', () async {
    final h = Harness(
      db,
      FakeHealthDataSource(granted: HcDataType.values.toSet()),
      now,
    );
    final result = await h.service.sync();
    expect(result.outcome, SyncOutcome.notEnabled);
    expect(h.fake.readCalls, 0);
  });

  test('syncIfStale throttles resume syncs to 5 minutes', () async {
    final h = await connected();
    await h.service.sync();
    final again = await h.service.syncIfStale();
    expect(again.outcome, SyncOutcome.skipped);
  });

  test(
    'manual steps are secondary to Health Connect for the same day',
    () async {
      final h = await connected();
      await h.repo.setManualSteps(today, 9000);
      await h.repo.setManualSteps(LocalDates.addDays(today, -5), 4321);
      await h.service.sync();

      final t = (await h.repo.stepsForDay(today))!;
      expect(t.steps, 5400);
      expect(t.origin, 'health_connect');
      expect(t.overriddenManual, 9000);

      final manualOnly = (await h.repo.stepsForDay(
        LocalDates.addDays(today, -5),
      ))!;
      expect(manualOnly.steps, 4321);
      expect(manualOnly.isManual, isTrue);

      // Re-sync must not delete manual rows.
      await h.service.sync();
      expect((await h.repo.stepsForDay(today))!.overriddenManual, 9000);
    },
  );

  test('manual weight is stored with origin and device "manual"', () async {
    final h = await connected();
    await h.repo.addManualWeight(80.2);
    await h.service.sync();
    final rows = await (db.select(
      db.healthSamples,
    )..where((s) => s.type.equals(HealthKeys.weight))).get();
    expect(rows, hasLength(2));
    final manual = rows.firstWhere((r) => r.origin == 'manual');
    expect(manual.sourceDevice, 'manual');
    expect(manual.value, 80.2);
    expect(() => h.repo.addManualWeight(5), throwsArgumentError);
  });

  test('enabling a group requests only that group\'s types', () async {
    final h = Harness(db, FakeHealthDataSource(), now);
    final controller = HealthPermissionController(
      source: h.fake,
      settings: h.settings,
      sync: h.service,
    );
    final result = await controller.enableGroup(HealthGroup.sleep);
    expect(result, GroupEnableResult.granted);
    expect(h.fake.granted, {HcDataType.sleepSession});
    expect(await h.settings.enabledGroups(), {HealthGroup.sleep});

    h.fake.grantOnRequest = false;
    final denied = await controller.enableGroup(HealthGroup.heart);
    expect(denied, GroupEnableResult.denied);
    expect(await h.settings.enabledGroups(), {HealthGroup.sleep});
    // Let the fire-and-forget sync finish before the DB closes.
    while (h.service.isSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
}
