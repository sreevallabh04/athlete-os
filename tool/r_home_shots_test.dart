import 'dart:async';

// Visual QA for the r-home screens (Today, onboarding, planning, routine).
//
//   flutter test tool/r_home_shots_test.dart
//   flutter test tool/r_home_shots_test.dart --plain-name today
//
// Writes PNGs to build/shots/r-home/. Seed data lives here only (test DB);
// it is obviously test data and never ships in the app.
import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/boot/boot_sequence.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart';

final monEvening = DateTime(2026, 10, 26, 21, 40);
final monMorning = DateTime(2026, 10, 26, 6, 50);
final monMidday = DateTime(2026, 10, 26, 13, 5);

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(AthleteOsApp)));

/// Calibrated profile + a realistic (test-only) day.
Future<void> seedDay(
  WidgetTester tester,
  DateTime now, {
  bool calibrate = true,
  bool competition = false,
}) async {
  final c = _container(tester);
  final db = c.read(databaseProvider);
  final date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final yesterday = now.subtract(const Duration(days: 1));
  final yKey =
      '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-'
      '${yesterday.day.toString().padLeft(2, '0')}';
  Future<void> work() async {
    if (calibrate) {
      await c
          .read(calibrationServiceProvider)
          .engage(CalibrationAnswers.interviewDefaults());
    }
    if (now.hour >= 9) {
      await db
          .into(db.dailyHealthSummaries)
          .insert(
            DailyHealthSummariesCompanion.insert(
              localDate: date,
              type: 'steps',
              value: 6420,
              unit: 'count',
              origin: 'health_connect',
              computedAt: Value(now.subtract(const Duration(minutes: 14))),
            ),
          );
    }
    await db
        .into(db.dailyHealthSummaries)
        .insert(
          DailyHealthSummariesCompanion.insert(
            localDate: date,
            type: 'sleep_minutes',
            value: 412,
            unit: 'min',
            origin: 'health_connect',
            computedAt: Value(now.subtract(const Duration(hours: 1))),
          ),
        );
    Future<void> food(
      String id,
      String name,
      String meal,
      double kcal,
      double p,
      double carbs,
      double fat,
      int hoursAgo,
    ) => db
        .into(db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: id,
            name: name,
            mealType: meal,
            calories: kcal,
            proteinG: Value(p),
            carbsG: Value(carbs),
            fatG: Value(fat),
            source: 'custom',
            verification: 'user_entered',
            loggedAt: now.subtract(Duration(hours: hoursAgo)).toUtc(),
            localDate: date,
            tzName: 'Asia/Kolkata',
          ),
        );
    if (now.hour >= 9) {
      await food('f1', 'Egg-white omelette', 'breakfast', 420, 38, 30, 12, 9);
      await food('f2', 'Paneer rice bowl', 'lunch', 610, 34, 70, 18, 5);
      await food('f3', 'Greek yogurt', 'snack', 180, 20, 14, 4, 2);
      for (final (i, ml) in [500, 500, 750].indexed) {
        await db
            .into(db.waterLogs)
            .insert(
              WaterLogsCompanion.insert(
                id: 'w$i',
                amountMl: ml,
                loggedAt: now.subtract(Duration(hours: 8 - i * 3)).toUtc(),
                localDate: date,
              ),
            );
      }
    }
    await db
        .into(db.workouts)
        .insert(
          WorkoutsCompanion.insert(
            id: 'wk1',
            source: 'manual',
            title: 'Push · chest, shoulders',
            startAt: yesterday.copyWith(hour: 6, minute: 30).toUtc(),
            endAt: Value(yesterday.copyWith(hour: 7, minute: 40).toUtc()),
            localDate: yKey,
          ),
        );
    for (final (i, title, done) in [
      (1, 'Ship the Q4 roadmap draft', true),
      (2, 'Book posing coach session', false),
      (3, 'Groceries: paneer, eggs, curd', false),
    ]) {
      await db
          .into(db.tasks)
          .insert(
            TasksCompanion.insert(
              id: 't$i',
              title: title,
              localDate: date,
              priority: Value(i),
              done: Value(done),
            ),
          );
    }
    if (competition) {
      await db
          .into(db.competitions)
          .insert(
            CompetitionsCompanion.insert(
              id: 'c1',
              name: 'Test Classic (sample)',
              eventDate: '2027-03-14',
              tzName: 'Asia/Kolkata',
              division: const Value("Men's Physique"),
              location: const Value('Bengaluru'),
              createdAt: Value(DateTime(2026, 9, 1).toUtc()),
            ),
          );
    }
  }

  await drive(tester, work());
}

/// Completes [f] while pumping frames and letting real IO progress.
Future<void> drive(WidgetTester tester, Future<void> f) async {
  var done = false;
  Object? error;
  unawaited(
    f.then(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 400 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (error != null) throw error!;
  if (!done) throw StateError('seed did not complete');
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets(
    'today empty',
    (t) => shotRoute(t, AppPaths.today, 'r-home/today_empty', scrolls: 3),
  );
  testWidgets(
    'today seeded evening',
    (t) => shotRoute(
      t,
      AppPaths.today,
      'r-home/today_evening',
      now: monEvening,
      scrolls: 3,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets(
    'today seeded morning',
    (t) => shotRoute(
      t,
      AppPaths.today,
      'r-home/today_morning',
      now: monMorning,
      scrolls: 2,
      prepare: (t) => seedDay(t, monMorning, competition: true),
    ),
  );
  testWidgets(
    'today ring expanded',
    (t) => shotRoute(
      t,
      AppPaths.today,
      'r-home/today_ring',
      now: monMidday,
      prepare: (t) async {
        await seedDay(t, monMidday);
        for (var i = 0; i < 20; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 50));
        }
        await t.tap(find.text('PROTEIN'));
      },
    ),
  );
  testWidgets(
    'today briefing sheet',
    (t) => shotRoute(
      t,
      AppPaths.today,
      'r-home/today_briefing',
      now: monEvening,
      prepare: (t) async {
        await seedDay(t, monEvening);
        for (var i = 0; i < 20; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 50));
        }
        await t.tap(find.text('JARVIS · BRIEFING'));
      },
    ),
  );
  testWidgets(
    'today light',
    (t) => shotRoute(
      t,
      AppPaths.today,
      'r-home/today_light',
      now: monEvening,
      light: true,
      scrolls: 1,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets('today text 1.3', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await shotRoute(
      t,
      AppPaths.today,
      'r-home/today_text13',
      now: monMidday,
      scrolls: 1,
      prepare: (t) => seedDay(t, monMidday),
    );
  });

  Future<void> settleFrames(WidgetTester t, [int n = 12]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'onboarding welcome',
    (t) => shotRoute(t, AppPaths.onboarding, 'r-home/onb_welcome'),
  );
  testWidgets(
    'onboarding name',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'r-home/onb_name',
      prepare: (t) async {
        await settleFrames(t);
        await t.tap(find.text('Begin calibration'));
      },
    ),
  );
  testWidgets(
    'onboarding body',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'r-home/onb_body',
      prepare: (t) async {
        await settleFrames(t);
        await t.tap(find.text('Begin calibration'));
        for (var i = 0; i < 5; i++) {
          await settleFrames(t, 10);
          await t.tap(find.text('Next'));
        }
      },
    ),
  );
  testWidgets(
    'onboarding goal',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'r-home/onb_goal',
      prepare: (t) async {
        await settleFrames(t);
        await t.tap(find.text('Begin calibration'));
        await settleFrames(t, 10);
        await t.tap(find.text('Next'));
      },
    ),
  );
  testWidgets(
    'onboarding schedule',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'r-home/onb_schedule',
      prepare: (t) async {
        await settleFrames(t);
        await t.tap(find.text('Begin calibration'));
        for (var i = 0; i < 7; i++) {
          await settleFrames(t, 10);
          await t.tap(find.text('Next'));
        }
      },
    ),
  );
  testWidgets(
    'onboarding plan',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'r-home/onb_plan',
      scrolls: 2,
      prepare: (t) async {
        await settleFrames(t);
        await t.tap(find.text('Skip'));
      },
    ),
  );
  testWidgets(
    'routine',
    (t) => shotRoute(
      t,
      AppPaths.routine,
      'r-home/routine',
      now: monMidday,
      scrolls: 2,
      prepare: (t) => seedDay(t, monMidday),
    ),
  );
  testWidgets(
    'routine empty',
    (t) => shotRoute(t, AppPaths.routine, 'r-home/routine_empty'),
  );

  testWidgets(
    'settings',
    (t) => shotRoute(
      t,
      AppPaths.settings,
      'r-home/settings',
      scrolls: 2,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets(
    'planner',
    (t) => shotRoute(
      t,
      AppPaths.planner,
      'r-home/planner',
      now: monMidday,
      scrolls: 3,
      prepare: (t) => seedDay(t, monMidday),
    ),
  );
  testWidgets(
    'competition empty',
    (t) => shotRoute(t, AppPaths.competition, 'r-home/competition_empty'),
  );
  testWidgets(
    'competition',
    (t) => shotRoute(
      t,
      AppPaths.competition,
      'r-home/competition',
      now: monMidday,
      scrolls: 3,
      prepare: (t) => seedDay(t, monMidday, competition: true),
    ),
  );
  testWidgets(
    'reports',
    (t) => shotRoute(
      t,
      AppPaths.reports,
      'r-home/reports',
      now: monEvening,
      scrolls: 3,
      prepare: (t) async {
        await seedDay(t, monEvening);
        await settleFrames(t);
        await t.tap(find.text('Generate report'));
      },
    ),
  );
  testWidgets(
    'profile',
    (t) => shotRoute(
      t,
      AppPaths.profile,
      'r-home/profile',
      scrolls: 3,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets(
    'privacy',
    (t) => shotRoute(t, AppPaths.privacy, 'r-home/privacy', scrolls: 2),
  );
  testWidgets('boot', (t) async {
    BootGate.debugReset();
    await shotRoute(
      t,
      AppPaths.today,
      'r-home/boot',
      settle: const Duration(milliseconds: 1150),
      overrides: [bootSequenceEnabledProvider.overrideWithValue(true)],
    );
  });
}
