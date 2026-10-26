// Route coverage: every `AppPaths` constant must build in the real app
// (real router, in-memory DB) without exceptions or layout overflows, in a
// first-run (empty) state and in a seeded state. Each page is also scrolled
// to the end so lazily-built content is laid out too.
//
// The list of paths is read from lib/app/paths.dart itself, so a new route
// is covered automatically (and a route that needs an `:id` must be given a
// seeded id below, or this test fails loudly).
import 'dart:io';

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/journal_repository.dart';
import 'package:athlete_os/features/life/data/mood_repository.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/train/data/workout_repository.dart';
import 'package:athlete_os/features/train/domain/workout_draft.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/real_fonts.dart';
import 'accessibility_test.dart' show buttonsWithoutTap;
import '../helpers/test_app.dart';

final _now = DateTime(2026, 10, 26, 13, 5);
const _workoutId = 'qa-workout';
const _runId = 'qa-run';

/// `static const name = '/path';` pairs from lib/app/paths.dart.
Map<String, String> appPathConstants() {
  final src = File('lib/app/paths.dart').readAsStringSync();
  final re = RegExp(r"static const (\w+) = '([^']+)';");
  return {for (final m in re.allMatches(src)) m.group(1)!: m.group(2)!};
}

/// Resolves `:id` placeholders with ids that exist in the seeded DB.
String resolve(String path) => path
    .replaceFirst('/running/activity/:id', '/running/activity/$_runId')
    .replaceFirst('/workout/:id', '/workout/$_workoutId');

Future<void> seedEverything(AppDatabase db) async {
  final c = ProviderContainer(overrides: testOverrides(db, now: _now));
  try {
    await c
        .read(calibrationServiceProvider)
        .engage(CalibrationAnswers.interviewDefaults());
  } finally {
    c.dispose();
  }
  final today = LocalDates.key(_now);
  final yesterday = LocalDates.addDays(today, -1);
  final y = LocalDates.parse(yesterday);
  await WorkoutRepository(db).upsertWorkout(
    id: _workoutId,
    source: 'manual',
    draft: WorkoutDraft(
      title: 'Push',
      startAt: DateTime(y.year, y.month, y.day, 6, 30),
      endAt: DateTime(y.year, y.month, y.day, 7, 35),
      exercises: const [
        ExerciseDraft(
          name: 'Bench Press (Barbell)',
          muscleGroup: 'chest',
          sets: [
            SetDraft(type: 'warmup', weightKg: 40, reps: 10),
            SetDraft(weightKg: 72.5, reps: 6),
            SetDraft(weightKg: 72.5, reps: 5),
          ],
        ),
        ExerciseDraft(
          name: 'Cable Lateral Raise',
          muscleGroup: 'shoulders',
          sets: [SetDraft(weightKg: 7.5, reps: 14)],
        ),
      ],
    ),
  );
  await db
      .into(db.cardioActivities)
      .insert(
        CardioActivitiesCompanion.insert(
          id: _runId,
          source: 'health_connect',
          name: const Value('Easy Zone 2 run'),
          sportType: 'run',
          startAt: DateTime(y.year, y.month, y.day, 18, 10).toUtc(),
          localDate: yesterday,
          distanceM: const Value(5200),
          movingTimeS: const Value(1900),
          elapsedTimeS: const Value(1950),
          avgHeartRate: const Value(146),
          fetchedAt: Value(_now.toUtc()),
        ),
      );
  for (final (i, name, meal, kcal, p) in [
    (1, 'Egg-white omelette', 'breakfast', 420.0, 38.0),
    (2, 'Paneer rice bowl', 'lunch', 610.0, 34.0),
  ]) {
    await db
        .into(db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: 'qa-f$i',
            name: name,
            mealType: meal,
            calories: kcal,
            proteinG: Value(p),
            carbsG: const Value(40),
            fatG: const Value(12),
            source: 'custom',
            verification: 'user_entered',
            loggedAt: _now.subtract(Duration(hours: 6 - i * 2)).toUtc(),
            localDate: today,
            tzName: 'Asia/Kolkata',
          ),
        );
  }
  await db
      .into(db.waterLogs)
      .insert(
        WaterLogsCompanion.insert(
          id: 'qa-w1',
          amountMl: 750,
          loggedAt: _now.subtract(const Duration(hours: 2)).toUtc(),
          localDate: today,
        ),
      );
  await db
      .into(db.dailyHealthSummaries)
      .insert(
        DailyHealthSummariesCompanion.insert(
          localDate: today,
          type: 'steps',
          value: 6420,
          unit: 'count',
          origin: 'health_connect',
          computedAt: Value(_now.subtract(const Duration(minutes: 14))),
        ),
      );
  final clock = FixedClock(_now);
  final habits = HabitRepository(db, clock);
  final id = await habits.create(const HabitInput(name: 'Read 20 pages'));
  await habits.setStatus(id, today, HabitStatus.done);
  await MoodRepository(
    db,
    clock,
  ).add(const MoodInput(mood: 4, energy: 4, stress: 2, tags: ['focused']));
  await JournalRepository(
    db,
    clock,
  ).save(localDate: today, body: 'Solid push session. Protein on track.');
  await db
      .into(db.tasks)
      .insert(
        TasksCompanion.insert(
          id: 'qa-t1',
          title: 'Ship the draft',
          localDate: today,
        ),
      );
}

Future<void> _frames(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpRoute(
  WidgetTester tester,
  String location, {
  required bool seeded,
  double textScale = 1.0,
  bool checkSemantics = false,
}) async {
  final handle = checkSemantics ? tester.ensureSemantics() : null;
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  tester.view.padding = const FakeViewPadding(top: 88, bottom: 50);
  tester.view.viewPadding = const FakeViewPadding(top: 88, bottom: 50);
  addTearDown(tester.view.reset);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final db = newTestDb();
  if (seeded) await tester.runAsync(() => seedEverything(db));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...testOverrides(db, now: _now),
        routerProvider.overrideWith(
          (ref) => buildRouter(initialLocation: location),
        ),
      ],
      child: const AthleteOsApp(),
    ),
  );
  await _frames(tester, 30);
  if (checkSemantics) {
    expect(
      buttonsWithoutTap(tester),
      isEmpty,
      reason: 'enabled buttons TalkBack cannot activate on $location',
    );
  }

  // Scroll every primary scrollable to the end so lazy content lays out.
  for (var i = 0; i < 6; i++) {
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) break;
    final vertical = scrollables.evaluate().where((e) {
      final s = e.widget as Scrollable;
      return axisDirectionToAxis(s.axisDirection) == Axis.vertical;
    });
    if (vertical.isEmpty) break;
    await tester.drag(
      find.byWidget(vertical.first.widget),
      const Offset(0, -700),
      warnIfMissed: false,
    );
    await _frames(tester, 6);
  }

  handle?.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(db.close);
}

void main() {
  setUpAll(loadRealFonts);
  final paths = appPathConstants();

  test('paths.dart parses and every :id route has a seeded id', () {
    expect(paths.length, greaterThanOrEqualTo(30));
    for (final p in paths.values) {
      expect(resolve(p), isNot(contains(':')), reason: '$p needs a seed id');
    }
  });

  for (final MapEntry(key: name, value: path) in paths.entries) {
    final location = resolve(path);
    testWidgets('$name ($location) builds empty', (t) async {
      await pumpRoute(t, location, seeded: false);
    });
    testWidgets('$name ($location) builds seeded', (t) async {
      await pumpRoute(t, location, seeded: true, checkSemantics: true);
    });
  }

  // Every route at the 1.3× text scale DESIGN.md promises.
  for (final MapEntry(key: name, value: path) in paths.entries) {
    testWidgets('$name builds seeded at 1.3× text', (t) async {
      await pumpRoute(t, resolve(path), seeded: true, textScale: 1.3);
    });
  }
}
