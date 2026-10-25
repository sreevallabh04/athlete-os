import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/util/ids.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/integrations/data/api_errors.dart';
import 'package:athlete_os/features/integrations/data/secret_store.dart';
import 'package:athlete_os/features/train/data/csv_import_service.dart';
import 'package:athlete_os/features/train/data/hevy_api_client.dart';
import 'package:athlete_os/features/train/data/hevy_sync_service.dart';
import 'package:athlete_os/features/train/data/workout_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

Map<String, dynamic> hevyWorkout(
  String id, {
  String title = 'Push',
  String updatedAt = '2026-10-20T10:00:00Z',
  double weight = 100,
}) => {
  'id': id,
  'title': title,
  'description': 'Felt good',
  'start_time': '2026-10-20T08:00:00Z',
  'end_time': '2026-10-20T09:00:00Z',
  'updated_at': updatedAt,
  'created_at': '2026-10-20T09:00:00Z',
  'exercises': [
    {
      'index': 0,
      'title': 'Bench Press (Barbell)',
      'notes': '',
      'exercise_template_id': 'T1',
      'superset_id': null,
      'sets': [
        {'index': 0, 'type': 'warmup', 'weight_kg': 60, 'reps': 10},
        {'index': 1, 'type': 'normal', 'weight_kg': weight, 'reps': 5},
        {'index': 2, 'type': 'normal', 'weight_kg': weight, 'reps': 5},
      ],
    },
    {
      'index': 1,
      'title': 'Custom Thing',
      'exercise_template_id': 'T9',
      'sets': [
        {'index': 0, 'type': 'normal', 'weight_kg': 20, 'reps': 12},
      ],
    },
  ],
};

class FakeHevyApi implements HevyApi {
  List<Map<String, dynamic>> workoutsList = [];
  List<HevyEvent> events = [];
  List<Map<String, dynamic>> templates = [
    {'id': 'T1', 'title': 'Bench Press', 'primary_muscle_group': 'chest'},
  ];
  int templateCalls = 0;
  bool invalidKey = false;
  DateTime? lastSince;

  @override
  Future<Map<String, dynamic>> userInfo() async {
    if (invalidKey) throw InvalidCredentialsException('Invalid API key');
    return {
      'data': {'name': 'athlete'},
    };
  }

  HevyPage<T> _page<T>(List<T> all, int page, int size) {
    final count = (all.length / size).ceil();
    final start = (page - 1) * size;
    return HevyPage(
      page: page,
      pageCount: count,
      items: start >= all.length
          ? []
          : all.sublist(start, (start + size).clamp(0, all.length)),
    );
  }

  @override
  Future<HevyPage<Map<String, dynamic>>> workouts({
    int page = 1,
    int pageSize = 10,
  }) async => _page(workoutsList, page, pageSize);

  @override
  Future<HevyPage<HevyEvent>> workoutEvents({
    required DateTime since,
    int page = 1,
    int pageSize = 10,
  }) async {
    lastSince = since;
    return _page(events, page, pageSize);
  }

  @override
  Future<HevyPage<Map<String, dynamic>>> exerciseTemplates({
    int page = 1,
    int pageSize = 100,
  }) async {
    templateCalls++;
    return _page(templates, page, pageSize);
  }
}

void main() {
  late AppDatabase db;
  late FakeHevyApi api;
  late HevySyncService service;
  late WorkoutRepository repo;
  late IntegrationStatusRepository status;
  late InMemorySecretStore secrets;

  setUp(() {
    db = newTestDb();
    api = FakeHevyApi();
    repo = WorkoutRepository(db);
    status = IntegrationStatusRepository(db);
    secrets = InMemorySecretStore();
    service = HevySyncService(
      db: db,
      workouts: repo,
      status: status,
      settings: SettingsRepository(db),
      secrets: secrets,
      apiFactory: (_) => api,
      clock: FixedClock(DateTime.utc(2026, 10, 25, 9, 7)),
    );
  });
  tearDown(() => db.close());

  Future<(int, int, int)> counts() async => (
    (await db.select(db.workouts).get()).length,
    (await db.select(db.workoutExercises).get()).length,
    (await db.select(db.workoutSets).get()).length,
  );

  test('connect stores key only after a successful test call', () async {
    api.invalidKey = true;
    await expectLater(
      service.connect('bad'),
      throwsA(isA<InvalidCredentialsException>()),
    );
    expect(await secrets.read(SecretKeys.hevyApiKey), isNull);
    final row = await status.get(Providers.hevy);
    expect(row!.status, ConnectionStates.error);
    expect(row.lastError, 'Invalid API key');

    api.invalidKey = false;
    await service.connect(' good-key ');
    expect(await secrets.read(SecretKeys.hevyApiKey), 'good-key');
    expect(
      (await status.get(Providers.hevy))!.status,
      ConnectionStates.connected,
    );
  });

  test('full import is idempotent and maps muscles from templates', () async {
    await service.connect('k');
    api.workoutsList = [
      for (var i = 0; i < 23; i++)
        hevyWorkout('w$i', updatedAt: '2026-10-${(i % 9) + 10}T10:00:00Z'),
    ];
    final r1 = await service.sync();
    expect(r1.fullImport, isTrue);
    expect(r1.upserted, 23);
    final c1 = await counts();
    expect(c1, (23, 46, 92));

    // Importing again (reset cursor) gives the same counts.
    await (db.update(db.integrationConnections))
        .write(const IntegrationConnectionsCompanion(cursor: Value(null)));
    await service.sync();
    expect(await counts(), c1);

    final logs = await repo.loadLogs();
    final bench = logs.first.exercises.firstWhere(
      (e) => e.name.startsWith('Bench'),
    );
    expect(bench.muscleGroup, 'chest');
    final custom = logs.first.exercises.firstWhere(
      (e) => e.name == 'Custom Thing',
    );
    expect(custom.muscleGroup, isNull);
    expect(bench.sets.first.type, 'warmup');

    final row = await status.get(Providers.hevy);
    expect(row!.cursor, '2026-10-18T10:00:00.000Z');
    expect(row.lastSyncAt, isNotNull);
    // Templates fetched once per week, not on every sync.
    expect(api.templateCalls, 1);
  });

  test(
    'incremental events: updated replaces sets, deleted soft-deletes',
    () async {
      await service.connect('k');
      api.workoutsList = [hevyWorkout('a'), hevyWorkout('b')];
      await service.sync();

      api.events = [
        HevyUpdatedEvent(
          hevyWorkout('a', updatedAt: '2026-10-21T10:00:00Z', weight: 105),
        ),
        HevyDeletedEvent('b', DateTime.utc(2026, 10, 22)),
      ];
      final r = await service.sync();
      expect(r.fullImport, isFalse);
      expect(r.upserted, 1);
      expect(r.deleted, 1);
      expect(api.lastSince, DateTime.utc(2026, 10, 20, 10));

      // No duplicated sets after replace.
      expect((await counts()).$3, 8);
      final logs = await repo.loadLogs();
      expect(logs.map((w) => w.id), [stableId('hevy', 'a')]);
      expect(logs.single.exercises.first.sets[1].weightKg, 105);
      final b = await (db.select(
        db.workouts,
      )..where((w) => w.id.equals(stableId('hevy', 'b')))).getSingle();
      expect(b.deletedAt, isNotNull);
      expect(
        (await status.get(Providers.hevy))!.cursor,
        '2026-10-22T00:00:00.000Z',
      );
    },
  );

  test('disconnect deletes key and optionally data', () async {
    await service.connect('k');
    api.workoutsList = [hevyWorkout('a')];
    await service.sync();
    await service.disconnect(deleteData: false);
    expect(await secrets.read(SecretKeys.hevyApiKey), isNull);
    expect(await repo.countActive(source: 'hevy'), 1);
    await service.disconnect(deleteData: true);
    expect(await repo.countActive(source: 'hevy'), 0);
    expect((await counts()).$3, 0);
  });

  test('CSV import is idempotent', () async {
    const csv =
        'title,start_time,end_time,description,exercise_title,superset_id,'
        'exercise_notes,set_index,set_type,weight_kg,reps,distance_km,'
        'duration_seconds,rpe\n'
        'Legs,"20 Oct 2026, 07:00","20 Oct 2026, 08:00",,Squat (Barbell),,,0,'
        'warmup,60,8,,,\n'
        'Legs,"20 Oct 2026, 07:00","20 Oct 2026, 08:00",,Squat (Barbell),,,1,'
        'normal,120,5,,,8\n';
    final csvService = CsvImportService(repo);
    final s1 = await csvService.importText(csv);
    final s2 = await csvService.importText(csv);
    expect(s1.imported, 1);
    expect(s2.imported, 1);
    expect(await counts(), (1, 1, 2));
    final w = (await repo.loadLogs()).single;
    expect(w.source, 'csv');
    expect(w.id, stableId('csv', 'Legs|20 Oct 2026, 07:00'));
  });
}
