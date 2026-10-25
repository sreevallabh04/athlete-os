// Visual QA for the Train / Health / Integrations redesign.
//
//   flutter test tool/r_train_shots_test.dart                    # every shot
//   flutter test tool/r_train_shots_test.dart --plain-name train  # a subset
//
// Each owned screen is rendered twice:
// * "empty": first run right after JARVIS calibration (real program,
//   targets and routine; no logs, no Health Connect).
// * "seeded": ~8 weeks of Hevy-like lifting with progressive loads, 12 runs
//   with splits trending faster, 30 days of steps, sleep and a weight trend
//   from 78 → 77.2 kg. Test-only data; nothing here ships.
//
// PNGs land in build/shots/r-train/.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/health/application/health_providers.dart';
import 'package:athlete_os/features/health/data/fake_health_data_source.dart';
import 'package:athlete_os/features/health/data/health_repository.dart';
import 'package:athlete_os/features/health/data/health_settings.dart';
import 'package:athlete_os/features/health/domain/health_types.dart';
import 'package:athlete_os/features/integrations/data/google_calendar_service.dart';
import 'package:athlete_os/features/integrations/presentation/calendar_screen.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:athlete_os/features/train/data/workout_repository.dart';
import 'package:athlete_os/features/train/domain/running_models.dart';
import 'package:athlete_os/features/train/domain/workout_draft.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers/test_app.dart';
import 'screenshots_test.dart' show loadShotFonts, shotDpr, shotPhysicalSize;

const _dir = 'build/shots/r-train';

/// Friday 23 Oct 2026, 06:05 — before the early-morning session.
final friMorning = DateTime(2026, 10, 23, 6, 5);

/// Friday afternoon (steps / health).
final friAfternoon = DateTime(2026, 10, 23, 15, 20);

typedef Seed = Future<void> Function(AppDatabase db, DateTime now);

Future<void> shot(
  WidgetTester tester,
  String path,
  String name, {
  required DateTime now,
  Seed? seed,
  int scrolls = 0,
  bool light = false,
  List<Override> overrides = const [],
  Future<void> Function(WidgetTester tester)? interact,
  Duration settle = const Duration(milliseconds: 2200),
}) async {
  await tester.runAsync(loadShotFonts);
  tester.view.physicalSize = shotPhysicalSize;
  tester.view.devicePixelRatio = shotDpr;
  tester.view.padding = const FakeViewPadding(
    top: 32 * shotDpr,
    bottom: 18 * shotDpr,
  );
  tester.view.viewPadding = const FakeViewPadding(
    top: 32 * shotDpr,
    bottom: 18 * shotDpr,
  );
  addTearDown(tester.view.reset);

  final db = newTestDb();
  if (seed != null) await tester.runAsync(() => seed(db, now));
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          ...testOverrides(db, now: now),
          routerProvider.overrideWith(
            (ref) => buildRouter(initialLocation: path),
          ),
          if (light)
            themeModeSettingProvider.overrideWith(
              (ref) => Stream.value('light'),
            ),
          ...overrides,
        ],
        child: const AthleteOsApp(),
      ),
    ),
  );
  await _advance(tester, settle);
  if (interact != null) {
    await interact(tester);
    await _advance(tester, const Duration(milliseconds: 1400));
  }
  await _capture(tester, key, name);
  for (var i = 1; i <= scrolls; i++) {
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) break;
    await tester.drag(
      scrollable.first,
      Offset(0, -shotPhysicalSize.height / shotDpr * 0.78),
    );
    await _advance(tester, const Duration(milliseconds: 1300));
    await _capture(tester, key, '${name}_$i');
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(db.close);
}

Future<void> _advance(WidgetTester tester, Duration d) async {
  final steps = (d.inMilliseconds / 50).ceil();
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: shotDpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_dir/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
  // ignore: avoid_print
  print('shot → $_dir/$name.png');
}

// ---------------------------------------------------------------------------
// Seeds
// ---------------------------------------------------------------------------

/// First run: JARVIS calibration with the interview defaults (his real
/// targets, program, routine). No training or health data.
Future<void> seedCalibrated(AppDatabase db, DateTime now) async {
  final c = ProviderContainer(overrides: testOverrides(db, now: now));
  try {
    await c
        .read(calibrationServiceProvider)
        .engage(CalibrationAnswers.interviewDefaults());
  } finally {
    c.dispose();
  }
}

/// Program whose week 1 started [weeksAgo] weeks before this week.
Future<void> setProgramStart(AppDatabase db, DateTime now, int weeksAgo) {
  final monday = LocalDates.weekStart(LocalDates.key(now));
  return SettingsRepository(db).set(
    PersonaKeys.program,
    generateMensPhysiqueProgram(
      startMonday: LocalDates.addDays(monday, -7 * weeksAgo),
    ).toJson(),
  );
}

class _Rng {
  _Rng(this._s);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }

  int range(int lo, int hi) => lo + (next() * (hi - lo + 1)).floor();
}

typedef _Ex = (String name, String? muscle, double base, double step, int reps);

const _push = <_Ex>[
  ('Bench Press (Barbell)', 'chest', 70, 1.25, 6),
  ('Incline Dumbbell Press', 'chest', 24, 0.5, 8),
  ('Seated Dumbbell Shoulder Press', 'shoulders', 20, 0.5, 9),
  ('Cable Lateral Raise', 'shoulders', 7.5, 0.3, 14),
  ('Overhead Cable Triceps Extension', 'triceps', 25, 0.6, 11),
];
const _pull = <_Ex>[
  ('Pull Up (Weighted)', 'lats', 5, 1.25, 6),
  ('Lat Pulldown (Cable)', 'lats', 60, 1.25, 10),
  ('Chest-Supported T-Bar Row', 'upper_back', 50, 1.25, 9),
  ('Reverse Pec Deck', 'shoulders', 35, 0.6, 15),
  ('Incline Dumbbell Curl', 'biceps', 12, 0.25, 10),
];
const _legs = <_Ex>[
  ('Squat (Barbell)', 'quadriceps', 85, 2.5, 6),
  ('Romanian Deadlift (Barbell)', 'hamstrings', 80, 1.25, 8),
  ('Leg Press (Machine)', 'quadriceps', 160, 5, 12),
  ('Seated Leg Curl (Machine)', 'hamstrings', 45, 1.25, 12),
  ('Standing Calf Raise', 'calves', 60, 1.25, 12),
  ('Cable Crunch', 'abdominals', 40, 1.25, 13),
];
const _upper = <_Ex>[
  ('Pull Up (Weighted)', 'lats', 5, 1.25, 7),
  ('Machine Shoulder Press', 'shoulders', 40, 1.25, 10),
  ('Lateral Raise (Dumbbell)', 'shoulders', 9, 0.25, 14),
  ('Incline Chest Press (Machine)', 'chest', 50, 1.25, 10),
  ('EZ Bar Curl', 'biceps', 30, 0.6, 10),
  ('Triceps Rope Pushdown', 'triceps', 30, 0.6, 12),
];
const _pump = <_Ex>[
  ('Cable Lateral Raise', 'shoulders', 6, 0.25, 18),
  ('Straight-Arm Pulldown', 'lats', 25, 0.6, 14),
  ('Cable Curl', 'biceps', 20, 0.5, 14),
  ('Stomach Vacuum + Posing', null, 0, 0, 0),
];

Future<void> seedTraining(AppDatabase db, DateTime now) async {
  final repo = WorkoutRepository(db);
  final rng = _Rng(42);
  final monday = LocalDates.parse(LocalDates.weekStart(LocalDates.key(now)));
  const weeks = 8;
  const skip = {(1, 7), (4, 2), (6, 4)}; // (week, weekday) missed sessions
  for (var w = 0; w < weeks; w++) {
    final weekMonday = DateTime(
      monday.year,
      monday.month,
      monday.day - 7 * (weeks - 1 - w),
    );
    final deload = w == 2; // program week 6 when the program began 7 wks ago
    for (final (weekday, title, list) in [
      (1, 'Push', _push),
      (2, 'Pull', _pull),
      (4, 'Legs + abs', _legs),
      (5, 'Upper · V-taper', _upper),
      (7, 'Weak-point pump', _pump),
    ]) {
      if (skip.contains((w, weekday))) continue;
      final start = DateTime(
        weekMonday.year,
        weekMonday.month,
        weekMonday.day + weekday - 1,
        6,
        28 + rng.range(0, 9),
      );
      final end = start.add(Duration(minutes: 62 + rng.range(0, 14)));
      if (end.isAfter(now)) continue;
      final manual = w == weeks - 1 && weekday == 7;
      await repo.upsertWorkout(
        id: 'seed-$w-$weekday',
        source: manual ? 'manual' : 'hevy',
        draft: WorkoutDraft(
          title: title,
          startAt: start,
          endAt: end,
          exercises: [
            for (final (name, muscle, base, step, reps) in list)
              ExerciseDraft(
                name: name,
                muscleGroup: manual ? null : muscle,
                sets: base == 0
                    ? const [SetDraft(durationS: 600)]
                    : [
                        SetDraft(
                          type: 'warmup',
                          weightKg: (base * 0.6 / 2.5).round() * 2.5,
                          reps: 10,
                        ),
                        for (var s = 0; s < (deload ? 2 : 3); s++)
                          SetDraft(
                            weightKg: _load(
                              base + step * w * (deload ? 0.7 : 1),
                              base,
                            ),
                            reps: math.max(
                              3,
                              reps + rng.range(-1, 1) - s + (w.isOdd ? 1 : 0),
                            ),
                          ),
                      ],
              ),
          ],
        ),
      );
    }
  }
  final status = IntegrationStatusRepository(db);
  await status.setStatus(Providers.hevy, ConnectionStates.connected);
  await (db.update(
    db.integrationConnections,
  )..where((c) => c.provider.equals(Providers.hevy))).write(
    IntegrationConnectionsCompanion(
      lastSyncAt: Value(now.subtract(const Duration(hours: 9)).toUtc()),
    ),
  );
}

double _load(double v, double base) {
  final inc = base >= 40 ? 2.5 : (base >= 10 ? 1.0 : 0.5);
  return (v / inc).round() * inc;
}

Future<void> seedRuns(AppDatabase db, DateTime now) async {
  final rng = _Rng(7);
  final monday = LocalDates.parse(LocalDates.weekStart(LocalDates.key(now)));
  var n = 0;
  for (var w = 5; w >= 0; w--) {
    final weekMonday = DateTime(monday.year, monday.month, monday.day - 7 * w);
    for (final weekday in [3, 6]) {
      final at = DateTime(
        weekMonday.year,
        weekMonday.month,
        weekMonday.day + weekday - 1,
        6,
        34,
      );
      if (at.isAfter(now)) continue;
      final quality = weekday == 6;
      final progress = (5 - w) / 5; // 0 → 1
      final basePace = quality
          ? 412 -
                38 *
                    progress // 6:52 → 6:14 /km
          : 452 - 18 * progress; // 7:32 → 7:14 /km
      final km = quality ? 5 : (5 + rng.range(0, 2) * 0.5);
      final splits = <RunSplit>[];
      var total = 0;
      for (var k = 0; k < km.floor(); k++) {
        final drift = quality ? (k - 2) * -2.5 : (k - 2) * 1.5;
        final t = (basePace + drift + rng.range(-4, 4)).round();
        total += t;
        splits.add(
          RunSplit(
            distanceM: 1000,
            movingTimeS: t,
            avgHr: (quality ? 158.0 : 142.0) + k * 2.2 + rng.range(-2, 2),
            elevDiffM: (rng.range(-6, 6)).toDouble(),
          ),
        );
      }
      final rest = km - km.floor();
      if (rest > 0) {
        final t = (basePace * rest).round();
        total += t;
        splits.add(
          RunSplit(
            distanceM: rest * 1000,
            movingTimeS: t,
            avgHr: quality ? 166 : 149,
            elevDiffM: 2,
          ),
        );
      }
      final source = quality ? 'strava' : 'health_connect';
      final id = 'run-${n++}';
      await db
          .into(db.cardioActivities)
          .insert(
            CardioActivitiesCompanion.insert(
              id: id,
              source: source,
              externalId: Value('ext-$id'),
              name: Value(quality ? 'Saturday 5K session' : 'Easy Zone 2 run'),
              sportType: 'run',
              startAt: at.toUtc(),
              localDate: LocalDates.key(at),
              distanceM: Value(km * 1000),
              movingTimeS: Value(total),
              elapsedTimeS: Value(total + 40),
              avgHeartRate: Value(quality ? 161 : 145),
              maxHeartRate: Value(quality ? 178 : 158),
              elevationGainM: Value(18.0 + rng.range(0, 14)),
              splitsJson: Value(
                source == 'strava' ? RunSplit.listToJson(splits) : null,
              ),
              fetchedAt: Value(now.toUtc()),
            ),
          );
      // The latest Strava run also exists in Health Connect (dedupe demo).
      if (quality && w == 0) {
        await db
            .into(db.cardioActivities)
            .insert(
              CardioActivitiesCompanion.insert(
                id: '$id-hc',
                source: 'health_connect',
                externalId: Value('hc-$id'),
                name: const Value('Running'),
                sportType: 'run',
                startAt: at.add(const Duration(seconds: 20)).toUtc(),
                localDate: LocalDates.key(at),
                distanceM: Value(km * 1000 + 30),
                movingTimeS: Value(total + 12),
                fetchedAt: Value(now.toUtc()),
              ),
            );
      }
    }
  }
}

Future<void> seedHealth(AppDatabase db, DateTime now) async {
  final repo = HealthRepository(db, FixedClock(now));
  final rng = _Rng(99);
  final today = LocalDates.key(now);
  final steps = <String, ({double value, String? sources})>{};
  final sleep = <String, ({double value, String? sources})>{};
  final kcal = <String, ({double value, String? sources})>{};
  for (var i = 29; i >= 0; i--) {
    final d = LocalDates.addDays(today, -i);
    final weekday = LocalDates.parse(d).weekday;
    final base = weekday == 6 ? 15200 : (weekday == 7 ? 9800 : 11800);
    final v = i == 0
        ? 7640
        : (base + rng.range(-2600, 2400) + (29 - i) * 25).toDouble();
    steps[d] = (value: v.toDouble(), sources: 'Google Fit');
    if (i < 14) {
      sleep[d] = (
        value: (400 + rng.range(-35, 45)).toDouble(),
        sources: 'Google Fit',
      );
    }
    kcal[d] = (
      value: (i == 0 ? 210 : 380 + rng.range(-90, 160)).toDouble(),
      sources: 'Google Fit',
    );
  }
  final start = LocalDates.addDays(today, -29);
  await repo.replaceDailySummaries(
    type: HealthKeys.steps,
    unit: 'count',
    startDate: start,
    endDate: today,
    values: steps,
  );
  await repo.replaceDailySummaries(
    type: HealthKeys.sleepMinutes,
    unit: 'min',
    startDate: start,
    endDate: today,
    values: sleep,
  );
  await repo.replaceDailySummaries(
    type: HealthKeys.activeKcal,
    unit: 'kcal',
    startDate: start,
    endDate: today,
    values: kcal,
  );
  // Calibration logged a weigh-in "now"; replace it with a realistic series.
  await (db.delete(
    db.healthSamples,
  )..where((h) => h.type.equals(HealthKeys.weight))).go();
  // Weight 78.0 → 77.2 over 30 days, every ~2 days, morning, manual.
  for (var i = 30; i >= 0; i -= 2) {
    final at = DateTime(now.year, now.month, now.day - i, 6, 12);
    final trend = 78.0 - 0.8 * (30 - i) / 30;
    final noise = (rng.next() - 0.5) * 0.5;
    await repo.addManualWeight(
      double.parse((trend + noise).toStringAsFixed(1)),
      at: at,
    );
  }
  final settings = HealthSettings(SettingsRepository(db));
  for (final g in [HealthGroup.activity, HealthGroup.sleep, HealthGroup.body]) {
    await settings.setGroupEnabled(g, true);
  }
  await IntegrationStatusRepository(db)
      .setStatus(Providers.healthConnect, ConnectionStates.connected);
  await (db.update(
    db.integrationConnections,
  )..where((c) => c.provider.equals(Providers.healthConnect))).write(
    IntegrationConnectionsCompanion(
      lastSyncAt: Value(now.subtract(const Duration(minutes: 24)).toUtc()),
    ),
  );
}

Future<void> seedAll(AppDatabase db, DateTime now) async {
  await seedCalibrated(db, now);
  await setProgramStart(db, now, 7);
  await seedTraining(db, now);
  await seedRuns(db, now);
  await seedHealth(db, now);
}

/// Phone-only reality: Health Connect available, activity/sleep/body granted,
/// no heart-rate permission (no watch).
FakeHealthDataSource seededHc() => FakeHealthDataSource(
  granted: {
    HcDataType.steps,
    HcDataType.distance,
    HcDataType.activeCalories,
    HcDataType.totalCalories,
    HcDataType.exercise,
    HcDataType.sleepSession,
    HcDataType.weight,
  },
);

/// First run on the OPPO (Android 13): Health Connect not installed.
FakeHealthDataSource emptyHc() =>
    FakeHealthDataSource(status: HcSdkStatus.needsInstall);

List<Override> seededOverrides() => [
  healthDataSourceProvider.overrideWithValue(seededHc()),
];
List<Override> emptyOverrides() => [
  healthDataSourceProvider.overrideWithValue(emptyHc()),
];

/// A connected Google Calendar with a realistic office day.
class _FakeCalendar extends GoogleCalendarService {
  _FakeCalendar(DateTime fixed, AppDatabase db)
    : super(
        db: db,
        status: IntegrationStatusRepository(db),
        settings: SettingsRepository(db),
        clock: FixedClock(fixed),
      );

  @override
  Future<List<CalendarEventView>> eventsBetween(
    DateTime start,
    DateTime end,
  ) async {
    final out = <CalendarEventView>[];
    var d = DateTime(start.year, start.month, start.day);
    var i = 0;
    while (d.isBefore(end)) {
      CalendarEventView ev(int h, int m, int minutes, String title) =>
          CalendarEventView(
            id: 'e${i++}',
            calendarId: 'primary',
            title: title,
            start: DateTime(d.year, d.month, d.day, h, m),
            end: DateTime(d.year, d.month, d.day, h, m + minutes),
          );
      if (d.weekday <= 5) {
        out.addAll([
          ev(10, 30, 30, 'Stand-up'),
          ev(12, 0, 60, 'Design review'),
          ev(14, 30, 45, 'Sprint planning'),
          if (d.weekday.isOdd) ev(16, 30, 60, '1:1 with lead'),
        ]);
      } else {
        out.add(ev(11, 0, 90, 'Family brunch'));
      }
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out
        .where((e) => e.start.isBefore(end) && e.end.isAfter(start))
        .toList();
  }
}

void main() {
  setUpAll(loadShotFonts);

  // ── Train tab ──────────────────────────────────────────────────────────
  testWidgets('train empty', (t) async {
    await shot(
      t,
      AppPaths.train,
      'train_empty',
      now: friMorning,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('train seeded', (t) async {
    await shot(
      t,
      AppPaths.train,
      'train_seeded',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('train seeded light', (t) async {
    await shot(
      t,
      AppPaths.train,
      'train_seeded_light',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      light: true,
    );
  });

  // ── Program ────────────────────────────────────────────────────────────
  testWidgets('program empty', (t) async {
    await shot(
      t,
      AppPaths.program,
      'program_empty',
      now: friMorning,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('program seeded', (t) async {
    await shot(
      t,
      AppPaths.program,
      'program_seeded',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('program run day', (t) async {
    await shot(
      t,
      AppPaths.program,
      'program_run',
      now: DateTime(2026, 10, 24, 6, 0),
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('program deload', (t) async {
    await shot(
      t,
      AppPaths.program,
      'program_deload',
      now: friMorning,
      seed: (db, now) async {
        await seedCalibrated(db, now);
        await setProgramStart(db, now, 5);
      },
      overrides: emptyOverrides(),
    );
  });

  // ── Strength ───────────────────────────────────────────────────────────
  testWidgets('strength empty', (t) async {
    await shot(
      t,
      AppPaths.strength,
      'strength_empty',
      now: friMorning,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
    );
  });
  testWidgets('strength seeded', (t) async {
    await shot(
      t,
      AppPaths.strength,
      'strength_seeded',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 3,
    );
  });

  // ── Running ────────────────────────────────────────────────────────────
  testWidgets('running empty', (t) async {
    await shot(
      t,
      AppPaths.running,
      'running_empty',
      now: friMorning,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
    );
  });
  testWidgets('running seeded', (t) async {
    await shot(
      t,
      AppPaths.running,
      'running_seeded',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('activity strava', (t) async {
    await shot(
      t,
      '/running/activity/run-9',
      'activity_strava',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 2,
    );
  });

  // ── Workout detail / log ───────────────────────────────────────────────
  testWidgets('workout detail', (t) async {
    await shot(
      t,
      '/workout/seed-7-4',
      'workout_detail',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    );
  });

  // ── Health ─────────────────────────────────────────────────────────────
  testWidgets('steps empty', (t) async {
    await shot(
      t,
      AppPaths.steps,
      'steps_empty',
      now: friAfternoon,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('steps seeded', (t) async {
    await shot(
      t,
      AppPaths.steps,
      'steps_seeded',
      now: friAfternoon,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('health empty', (t) async {
    await shot(
      t,
      AppPaths.healthOverview,
      'health_empty',
      now: friAfternoon,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('health seeded', (t) async {
    await shot(
      t,
      AppPaths.healthOverview,
      'health_seeded',
      now: friAfternoon,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('health status empty', (t) async {
    await shot(
      t,
      AppPaths.healthStatus,
      'hc_status_empty',
      now: friAfternoon,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('health status seeded', (t) async {
    await shot(
      t,
      AppPaths.healthStatus,
      'hc_status_seeded',
      now: friAfternoon,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 2,
    );
  });

  // ── Integrations / calendar ────────────────────────────────────────────
  testWidgets('integrations empty', (t) async {
    await shot(
      t,
      AppPaths.integrations,
      'integrations_empty',
      now: friMorning,
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 2,
    );
  });
  testWidgets('integrations seeded', (t) async {
    await shot(
      t,
      AppPaths.integrations,
      'integrations_seeded',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('calendar empty', (t) async {
    await shot(
      t,
      AppPaths.calendar,
      'calendar_empty',
      now: DateTime(2026, 10, 23, 9, 10),
      seed: seedCalibrated,
      overrides: emptyOverrides(),
      scrolls: 1,
    );
  });
  testWidgets('calendar connected', (t) async {
    await shot(
      t,
      AppPaths.calendar,
      'calendar_connected',
      now: DateTime(2026, 10, 23, 9, 10),
      seed: (db, now) async {
        await seedAll(db, now);
        await IntegrationStatusRepository(db)
            .setStatus(Providers.googleCalendar, ConnectionStates.connected);
      },
      overrides: [
        ...seededOverrides(),
        calendarConfiguredProvider.overrideWithValue(true),
        googleCalendarServiceProvider.overrideWith(
          (ref) => _FakeCalendar(
            DateTime(2026, 10, 23, 9, 10),
            ref.watch(databaseProvider),
          ),
        ),
      ],
      scrolls: 1,
    );
  });
}
