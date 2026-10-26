// Cross-app QA sweep: the first-run journey (all 18 onboarding steps →
// Engage → Today) and every tab right after calibration, so "fresh install"
// screens are reviewed as carefully as seeded ones.
//
//   flutter test tool/qa_shots_test.dart --dart-define=SHOT_DIR=build/shots/qa
//
// The per-feature suites (r_home, r_train, r_life_*, r_coach) cover seeded
// states, sheets and dialogs; run them with the same SHOT_DIR for a full
// sweep.
import 'dart:async';

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart';

final _now = DateTime(2026, 10, 26, 7, 40);

Future<void> _frames(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Walks the onboarding to step [index] (0-based).
Future<void> _toStep(WidgetTester t, int index) async {
  await _frames(t, 12);
  if (index == 0) return;
  await t.tap(find.text('Begin calibration'));
  for (var i = 1; i < index; i++) {
    await _frames(t, 10);
    await t.tap(find.text('Next'));
  }
}

/// Calibrates with the interview defaults inside the running app (the same
/// call Engage makes), leaving every log empty.
Future<void> _calibrate(WidgetTester t) async {
  final c = ProviderScope.containerOf(t.element(find.byType(AthleteOsApp)));
  var done = false;
  Object? error;
  unawaited(
    c
        .read(calibrationServiceProvider)
        .engage(CalibrationAnswers.interviewDefaults())
        .then((_) => done = true, onError: (Object e) => error = e),
  );
  for (var i = 0; i < 400 && !done && error == null; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
  if (error != null) throw error!;
}

const _steps = [
  'welcome',
  'name',
  'goal',
  'competition',
  'diet',
  'experience',
  'body',
  'rate',
  'schedule',
  'split',
  'run',
  'daily',
  'persona',
  'rituals',
  'habits',
  'messaging',
  'wearable',
  'plan',
];

void main() {
  setUpAll(loadShotFonts);

  for (var i = 0; i < _steps.length; i++) {
    final name = 'onb/${(i + 1).toString().padLeft(2, '0')}_${_steps[i]}';
    testWidgets(
      'onboarding ${_steps[i]}',
      (t) => shotRoute(
        t,
        AppPaths.onboarding,
        name,
        now: _now,
        scrolls: 1,
        prepare: (t) => _toStep(t, i),
      ),
    );
  }

  for (final i in [1, 6, 8, 17]) {
    testWidgets('onboarding ${_steps[i]} text 1.3', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await shotRoute(
        t,
        AppPaths.onboarding,
        'onb/text13_${_steps[i]}',
        now: _now,
        prepare: (t) => _toStep(t, i),
      );
    });
  }

  testWidgets(
    'onboarding light',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'onb/light_goal',
      now: _now,
      light: true,
      prepare: (t) => _toStep(t, 2),
    ),
  );

  testWidgets(
    'engage lands on today',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      'onb/20_after_engage',
      now: _now,
      settle: const Duration(milliseconds: 3500),
      scrolls: 2,
      prepare: (t) async {
        await _toStep(t, 17);
        await _frames(t, 10);
        await t.tap(find.text('Engage'));
      },
    ),
  );

  // Every tab (and the plan screens) right after calibration: no logs yet.
  for (final (path, name, scrolls) in [
    (AppPaths.today, 'today', 2),
    (AppPaths.train, 'train', 2),
    (AppPaths.nutrition, 'nutrition', 1),
    (AppPaths.coach, 'coach', 0),
    (AppPaths.life, 'life', 1),
    (AppPaths.program, 'program', 1),
    (AppPaths.routine, 'routine', 1),
    (AppPaths.hydration, 'hydration', 0),
    (AppPaths.habits, 'habits', 0),
  ]) {
    testWidgets(
      'first run $name',
      (t) => shotRoute(
        t,
        path,
        'first/$name',
        now: _now,
        scrolls: scrolls,
        prepare: _calibrate,
      ),
    );
  }
}
