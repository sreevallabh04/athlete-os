// Visual QA for the "Stark" palette: the hero screens in one sweep.
//
//   flutter test tool/stark_shots_test.dart --dart-define=SHOT_DIR=build/shots/stark
//   flutter test tool/stark_shots_test.dart --dart-define=SHOT_DIR=build/shots/stark --dart-define=SHOT_TAG=v2
//
// Seeds come from the per-feature suites (test DB only).
import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:flutter_test/flutter_test.dart';

import 'r_home_shots_test.dart' show seedDay, monEvening;
import 'r_life_life_shots_test.dart' show seedLife;
import 'r_life_nutrition_shots_test.dart' show seedNutrition;
import 'r_train_shots_test.dart'
    show shot, seedAll, seededOverrides, friMorning;
import 'screenshots_test.dart';

const _tag = String.fromEnvironment('SHOT_TAG', defaultValue: 'v1');

Future<void> _frames(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets(
    'today',
    (t) => shotRoute(
      t,
      AppPaths.today,
      '$_tag/today',
      now: monEvening,
      scrolls: 2,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets(
    'today light',
    (t) => shotRoute(
      t,
      AppPaths.today,
      '$_tag/today_light',
      now: monEvening,
      light: true,
      scrolls: 1,
      prepare: (t) => seedDay(t, monEvening),
    ),
  );
  testWidgets(
    'nutrition',
    (t) => shotRoute(
      t,
      AppPaths.nutrition,
      '$_tag/nutrition',
      now: DateTime(2026, 10, 25, 18, 20),
      scrolls: 1,
      prepare: seedNutrition,
    ),
  );
  testWidgets(
    'train',
    (t) => shot(
      t,
      AppPaths.train,
      '../$_tag/train',
      now: friMorning,
      seed: seedAll,
      overrides: seededOverrides(),
      scrolls: 1,
    ),
  );
  testWidgets('coach', (t) => shotRoute(t, AppPaths.coach, '$_tag/coach'));
  testWidgets(
    'life',
    (t) => shotRoute(
      t,
      AppPaths.life,
      '$_tag/life',
      now: DateTime(2026, 10, 25, 21, 40),
      scrolls: 1,
      prepare: seedLife,
    ),
  );
  testWidgets(
    'onboarding plan',
    (t) => shotRoute(
      t,
      AppPaths.onboarding,
      '$_tag/onboarding_plan',
      now: DateTime(2026, 10, 26, 7, 40),
      scrolls: 1,
      prepare: (t) async {
        await _frames(t, 12);
        await t.tap(find.text('Begin calibration'));
        for (var i = 1; i < 17; i++) {
          await _frames(t, 10);
          await t.tap(find.text('Next'));
        }
      },
    ),
  );
  testWidgets(
    'gallery',
    (t) => shotRoute(t, AppPaths.devGallery, '$_tag/gallery', scrolls: 6),
  );
  // Keeps the import used when every seeded shot is filtered out.
  test('app type', () => expect(AthleteOsApp, isNotNull));
}
