import 'dart:convert';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/onboarding/domain/daily_routine.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:athlete_os/features/surfaces/domain/widget_snapshot.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:athlete_os/features/today/data/today_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  final now = DateTime(2026, 10, 26, 14, 30);
  const date = '2026-10-26';

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = newTestDb();
    container = ProviderContainer(overrides: testOverrides(db, now: now));
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<TodaySnapshot> load([DateTime? at]) =>
      container.read(todayRepositoryProvider).load(at ?? now);

  test(
    'empty day: every value is null (never 0), targets from profile',
    () async {
      final s = buildWidgetSnapshot(now: now, today: await load());

      expect(s.date, date);
      for (final m in [s.steps, s.protein, s.calories, s.water]) {
        expect(m.value, isNull);
        expect(m.target, isNotNull);
        expect(m.target, greaterThan(0));
        expect(m.progress, isNull);
      }
      expect(s.sessionTitle, isNull);
      expect(s.routine, isEmpty);

      final json = jsonDecode(s.encode()) as Map<String, Object?>;
      expect((json['steps'] as Map)['v'], isNull);
      expect((json['water'] as Map)['v'], isNull);
      expect(json['session'], isNull);
      expect(json['ver'], widgetSnapshotVersion);
    },
  );

  test('nothing loaded yet: values and targets are null', () {
    final s = buildWidgetSnapshot(now: now);
    for (final m in [s.steps, s.protein, s.calories, s.water]) {
      expect(m.value, isNull);
      expect(m.target, isNull);
    }
  });

  test('real logged/synced values are passed through', () async {
    await db
        .into(db.dailyHealthSummaries)
        .insert(
          DailyHealthSummariesCompanion.insert(
            localDate: date,
            type: 'steps',
            value: 6240,
            unit: 'count',
            origin: 'health_connect',
            computedAt: Value(now),
          ),
        );
    await db
        .into(db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: 'f1',
            name: 'Eggs',
            mealType: 'breakfast',
            calories: 450,
            proteinG: const Value(38),
            source: 'custom',
            verification: 'user_entered',
            loggedAt: now.toUtc(),
            localDate: date,
            tzName: 'UTC',
          ),
        );
    await db
        .into(db.waterLogs)
        .insert(
          WaterLogsCompanion.insert(
            id: 'w1',
            amountMl: 750,
            loggedAt: now.toUtc(),
            localDate: date,
          ),
        );

    final s = buildWidgetSnapshot(now: now, today: await load());
    expect(s.steps.value, 6240);
    expect(s.protein.value, 38);
    expect(s.calories.value, 450);
    expect(s.water.value, 750);
    expect(s.water.progress, closeTo(750 / s.water.target!, 1e-9));
  });

  test('a snapshot of another day never leaks into today', () async {
    await db
        .into(db.waterLogs)
        .insert(
          WaterLogsCompanion.insert(
            id: 'w-yesterday',
            amountMl: 2000,
            loggedAt: now.subtract(const Duration(days: 1)).toUtc(),
            localDate: '2026-10-25',
          ),
        );
    final yesterday = await load(now.subtract(const Duration(days: 1)));
    expect(yesterday.waterMl, 2000);

    final s = buildWidgetSnapshot(now: now, today: yesterday);
    expect(s.date, date);
    expect(s.water.value, isNull);
    expect(s.water.target, isNotNull);
  });

  test('session title, kind and next routine block', () {
    final program = generateMensPhysiqueProgram(startMonday: '2026-10-19');
    final session = planSession(program: program, date: date);
    final s = buildWidgetSnapshot(
      now: now,
      session: session,
      routine: const [
        RoutineBlock(
          start: 18 * 60,
          end: 18 * 60 + 30,
          kind: RoutineKind.walk,
          title: 'Evening walk',
        ),
        RoutineBlock(
          start: 6 * 60 + 30,
          end: 7 * 60,
          kind: RoutineKind.wake,
          title: 'Wake',
        ),
      ],
    );
    expect(s.sessionTitle, isNotNull);
    expect(s.sessionTitle, contains(session.day.title));
    expect(s.sessionKind, session.day.kind.key);
    expect(s.sessionDone, isFalse);
    expect(s.routine.first.title, 'Wake', reason: 'sorted by start');
    expect(s.nextBlock(14 * 60 + 30)?.title, 'Evening walk');
    expect(s.nextBlock(19 * 60), isNull);
  });

  test('a planned session for another date is ignored', () {
    final program = generateMensPhysiqueProgram(startMonday: '2026-10-19');
    final s = buildWidgetSnapshot(
      now: now,
      session: planSession(program: program, date: '2026-10-25'),
    );
    expect(s.sessionTitle, isNull);
    expect(s.sessionKind, isNull);
  });

  test('contentKey ignores the timestamp only', () async {
    final today = await load();
    final a = buildWidgetSnapshot(now: now, today: today);
    final b = buildWidgetSnapshot(
      now: now.add(const Duration(minutes: 5)),
      today: today,
    );
    expect(a.encode(), isNot(b.encode()));
    expect(a.contentKey(), b.contentKey());
  });
}
