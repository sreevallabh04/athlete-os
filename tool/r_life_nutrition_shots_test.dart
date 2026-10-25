// Visual QA for the Nutrition feature (r-life redesign): first-run and
// seeded states of every Nutrition screen, one light-theme and one 1.3×
// text shot, plus sheets, the speed dial and the scanner overlay.
//
//   flutter test tool/r_life_nutrition_shots_test.dart
//   flutter test tool/r_life_nutrition_shots_test.dart --plain-name tab
//
// PNGs land in build/shots/r-life/nut_*.png. Seed data is test-only.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/util/ids.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/data/food_repository.dart';
import 'package:athlete_os/features/nutrition/domain/ai_contracts.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/presentation/barcode_scan_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/widgets/quick_add_fab.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart';

final _now = DateTime(2026, 10, 25, 18, 20);
const _dir = 'r-life';

AppDatabase _db(WidgetTester t) => ProviderScope.containerOf(
  t.element(find.byType(AthleteOsApp)),
  listen: false,
).read(databaseProvider);

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < (ms / 50).ceil(); i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Runs [work] in the test zone while pumping (see the Life shot tool:
/// wrapping DB writes in `runAsync` deadlocks drift).
Future<void> _drive(WidgetTester t, Future<void> work) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    work.then(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  for (var i = 0; !done && i < 20000; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  if (!done) throw StateError('seeding did not finish');
}

String _day(int offset) => LocalDates.key(_now.add(Duration(days: offset)));

DateTime _at(int dayOffset, int h, int m) =>
    DateTime(_now.year, _now.month, _now.day + dayOffset, h, m);

/// Profile targets of the real user, onboarding-style (no history).
Future<void> seedTargets(WidgetTester t) async {
  final db = _db(t);
  await _drive(
    t,
    ProfileRepository(db).update(
      const UserProfilesCompanion(
        calorieTarget: Value(2250),
        proteinTargetG: Value(170),
        carbsTargetG: Value(245),
        fatTargetG: Value(65),
        waterGoalMl: Value(3500),
        wakeMinutes: Value(360),
        sleepMinutes: Value(1350),
      ),
    ),
  );
}

/// Today: besan chilla + hung curd, dal-rice-paneer (+ soya), whey +
/// banana (~1,470 kcal / 110 g P); 1.75 L water; six prior days of
/// history (one unlogged) and a few weigh-ins.
Future<void> seedNutrition(WidgetTester t) async {
  await seedTargets(t);
  final db = _db(t);
  await _drive(
    t,
    db.transaction(() async {
      final foods = FoodRepository(db, FixedClock(_at(-8, 9, 0)));
      Future<Food> food(
        String name,
        Nutrients per,
        double size,
        String unit, {
        double? grams,
        String source = FoodSources.usda,
        String verification = Verifications.database,
        String? brand,
        bool fav = false,
      }) => foods.create(
        FoodDraft(
          name: name,
          brand: brand,
          basis: ServingBasis(
            perServing: per,
            servingSize: size,
            servingUnit: unit,
            gramsPerServing:
                grams ?? (unit == 'g' || unit == 'ml' ? size : null),
          ),
          source: source,
          verification: verification,
          isFavorite: fav,
        ),
      );

      final chilla = await food(
        'Besan chilla',
        const Nutrients(calories: 130, protein: 8.5, carbs: 14, fat: 5),
        1,
        'piece',
        grams: 60,
        source: FoodSources.custom,
        verification: Verifications.userEntered,
        fav: true,
      );
      final curd = await food(
        'Hung curd',
        const Nutrients(calories: 95, protein: 9.5, carbs: 4, fat: 4.5),
        100,
        'g',
        source: FoodSources.openFoodFacts,
        verification: Verifications.verifiedLabel,
      );
      final dal = await food(
        'Toor dal (cooked)',
        const Nutrients(calories: 116, protein: 7, carbs: 20, fat: 0.4),
        100,
        'g',
      );
      final rice = await food(
        'White rice (cooked)',
        const Nutrients(calories: 130, protein: 2.7, carbs: 28, fat: 0.3),
        100,
        'g',
      );
      final paneer = await food(
        'Paneer',
        const Nutrients(calories: 265, protein: 18.3, carbs: 1.2, fat: 20.8),
        100,
        'g',
        fav: true,
      );
      final soya = await food(
        'Soya chunks',
        const Nutrients(calories: 345, protein: 52, carbs: 33, fat: 0.5),
        100,
        'g',
      );
      final whey = await food(
        'Whey protein',
        const Nutrients(calories: 130, protein: 25, carbs: 3, fat: 1.5),
        33,
        'g',
        source: FoodSources.openFoodFacts,
        verification: Verifications.verifiedLabel,
        fav: true,
      );
      final banana = await food(
        'Banana',
        const Nutrients(calories: 105, protein: 1.3, carbs: 27, fat: 0.4),
        1,
        'piece',
        grams: 118,
      );
      final roti = await food(
        'Whole wheat roti',
        const Nutrients(calories: 104, protein: 3.6, carbs: 18, fat: 2.4),
        1,
        'piece',
        grams: 40,
        source: FoodSources.custom,
        verification: Verifications.userEntered,
      );
      final eggs = await food(
        'Boiled egg',
        const Nutrients(calories: 78, protein: 6.3, carbs: 0.6, fat: 5.3),
        1,
        'piece',
        grams: 50,
      );

      Future<void> log(
        int day,
        int h,
        int m,
        Food f,
        Amount a,
        MealType meal,
      ) => FoodLogRepository(
        db,
        FixedClock(_at(day, h, m)),
      ).logFood(f, amount: a, mealType: meal, localDate: _day(day));

      // Today.
      await log(0, 7, 42, chilla, const Amount.servings(2), MealType.breakfast);
      await log(0, 7, 42, curd, const Amount.grams(150), MealType.breakfast);
      await log(0, 13, 10, dal, const Amount.grams(200), MealType.lunch);
      await log(0, 13, 10, rice, const Amount.grams(180), MealType.lunch);
      await log(0, 13, 11, paneer, const Amount.grams(100), MealType.lunch);
      await log(0, 13, 11, soya, const Amount.grams(30), MealType.lunch);
      await log(0, 17, 5, whey, const Amount.servings(1), MealType.snack);
      await log(0, 17, 5, banana, const Amount.servings(1), MealType.snack);
      // Masala chai from the office pantry: an honest estimate.
      await FoodLogRepository(db, FixedClock(_at(0, 16, 30))).quickAdd(
        name: 'Masala chai',
        nutrients: const Nutrients(
          calories: 70,
          protein: 2,
          carbs: 9,
          fat: 2.5,
        ),
        mealType: MealType.snack,
        localDate: _day(0),
      );

      // Six prior days (day -4 not logged).
      const scale = {-1: 1.1, -2: 0.95, -3: 1.2, -5: 1.0, -6: 0.85};
      for (final e in scale.entries) {
        final d = e.key;
        final s = e.value;
        await log(
          d,
          7,
          30,
          eggs,
          Amount.servings(d.isEven ? 3 : 2),
          MealType.breakfast,
        );
        await log(d, 7, 31, roti, const Amount.servings(2), MealType.breakfast);
        await log(d, 13, 5, dal, Amount.grams(220 * s), MealType.lunch);
        await log(d, 13, 5, rice, Amount.grams(200 * s), MealType.lunch);
        await log(d, 13, 6, paneer, Amount.grams(120 * s), MealType.lunch);
        await log(d, 17, 0, whey, const Amount.servings(1), MealType.snack);
        await log(
          d,
          20,
          15,
          roti,
          Amount.servings(d.isEven ? 3 : 2),
          MealType.dinner,
        );
        await log(d, 20, 15, soya, Amount.grams(60 * s), MealType.dinner);
        await log(d, 20, 16, curd, const Amount.grams(150), MealType.dinner);
      }

      // Water: 1.75 L today, a week of history.
      for (final (h, m, ml) in const [
        (6, 20, 500),
        (9, 10, 250),
        (12, 40, 500),
        (15, 20, 250),
        (17, 45, 250),
      ]) {
        await WaterRepository(db, FixedClock(_at(0, h, m))).add(ml);
      }
      const week = {-1: 3200, -2: 3600, -3: 2800, -4: 3500, -5: 2400, -6: 3900};
      for (final e in week.entries) {
        var left = e.value;
        var h = 7;
        while (left > 0) {
          final ml = left >= 500 ? 500 : left;
          await WaterRepository(db, FixedClock(_at(e.key, h, 0))).add(ml);
          left -= ml;
          h += 2;
        }
      }

      // Weigh-ins (Health Connect scale).
      const kg = {-6: 78.4, -4: 78.1, -2: 77.9, 0: 77.6};
      for (final e in kg.entries) {
        final at = _at(e.key, 6, 40);
        await db
            .into(db.healthSamples)
            .insert(
              HealthSamplesCompanion.insert(
                id: newId(),
                type: 'weight',
                value: e.value,
                unit: 'kg',
                startAt: at.toUtc(),
                endAt: at.toUtc(),
                localDate: _day(e.key),
                sourceApp: const Value('com.sec.android.app.shealth'),
                sourceDevice: const Value('scale'),
                origin: 'health_connect',
                externalId: Value('w${e.key}'),
              ),
            );
      }
    }),
  );
}

Future<void> _tap(WidgetTester t, Finder f, {int settle = 900}) async {
  await _pump(t, 600);
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(
      f,
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
  }
  await t.ensureVisible(f.first);
  await t.pump(const Duration(milliseconds: 50));
  await t.tap(f.first, warnIfMissed: false);
  await _pump(t, settle);
}

class _FakeEstimator implements FoodTextEstimator {
  @override
  bool get isConfigured => true;
  @override
  Future<FoodEstimateResult> estimate(String text) async =>
      const FoodEstimateSuccess([
        EstimatedFood(
          name: 'Idli',
          quantityDescription: '3 medium idlis',
          grams: 120,
          nutrients: Nutrients(
            calories: 175,
            protein: 5.5,
            carbs: 37,
            fat: 0.6,
          ),
        ),
        EstimatedFood(
          name: 'Coconut chutney',
          quantityDescription: '2 tbsp',
          grams: 30,
          nutrients: Nutrients(calories: 85, protein: 1, carbs: 3, fat: 8),
        ),
      ]);
}

Future<void> _shot(
  WidgetTester t,
  String path,
  String name, {
  bool seed = false,
  bool targets = true,
  int scrolls = 0,
  bool light = false,
  List<Override> overrides = const [],
  Future<void> Function(WidgetTester t)? then,
}) => shotRoute(
  t,
  path,
  '$_dir/$name',
  now: _now,
  scrolls: scrolls,
  light: light,
  overrides: overrides,
  prepare: (t) async {
    if (seed) {
      await seedNutrition(t);
    } else if (targets) {
      await seedTargets(t);
    }
    if (then != null) await then(t);
  },
);

/// Renders a bare widget (no router) at phone size, for chrome that needs a
/// platform view in the real app (camera).
Future<void> _shotWidget(WidgetTester t, Widget child, String name) async {
  await t.runAsync(loadShotFonts);
  t.view.physicalSize = shotPhysicalSize;
  t.view.devicePixelRatio = shotDpr;
  t.view.padding = const FakeViewPadding(
    top: 32 * shotDpr,
    bottom: 18 * shotDpr,
  );
  addTearDown(t.view.reset);
  final key = GlobalKey();
  await t.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: child,
      ),
    ),
  );
  await _pump(t, 1400);
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: shotDpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/shots/$_dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
  await t.pumpWidget(const SizedBox());
}

const _add = '/nutrition/add?meal=lunch&date=2026-10-25';

void main() {
  setUpAll(loadShotFonts);

  // ── Nutrition tab ────────────────────────────────────────────────────
  testWidgets(
    'tab empty',
    (t) => _shot(t, '/nutrition', 'nut_tab_empty', scrolls: 2),
  );
  testWidgets(
    'tab seeded',
    (t) => _shot(t, '/nutrition', 'nut_tab', seed: true, scrolls: 3),
  );
  testWidgets(
    'tab light',
    (t) => _shot(
      t,
      '/nutrition',
      'nut_tab_light',
      seed: true,
      light: true,
      scrolls: 1,
    ),
  );
  testWidgets('tab text 1.3', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await _shot(t, '/nutrition', 'nut_tab_text13', seed: true, scrolls: 2);
  });
  testWidgets(
    'speed dial',
    (t) => _shot(
      t,
      '/nutrition',
      'nut_speed_dial',
      seed: true,
      then: (t) => _tap(t, find.byType(QuickAddFab)),
    ),
  );
  testWidgets(
    'edit entry sheet',
    (t) => _shot(
      t,
      '/nutrition',
      'nut_edit_sheet',
      seed: true,
      then: (t) => _tap(t, find.text('Paneer')),
    ),
  );
  testWidgets(
    'meal ideas sheet',
    (t) => _shot(
      t,
      '/nutrition',
      'nut_ideas_sheet',
      seed: true,
      then: (t) => _tap(t, find.text('What can I eat?')),
    ),
  );
  testWidgets(
    'past day',
    (t) => _shot(
      t,
      '/nutrition',
      'nut_tab_past',
      seed: true,
      then: (t) async {
        await _pump(t, 600);
        await t.fling(
          find.textContaining('KCAL').first,
          const Offset(400, 0),
          1500,
        );
        await _pump(t, 900);
      },
    ),
  );

  // ── Add food ─────────────────────────────────────────────────────────
  testWidgets('add search empty', (t) => _shot(t, _add, 'nut_add_search'));
  testWidgets(
    'add search typed',
    (t) => _shot(
      t,
      _add,
      'nut_add_search_typed',
      seed: true,
      then: (t) async {
        await _pump(t, 400);
        await t.enterText(find.byKey(const Key('food-search-field')), 'pa');
        await _pump(t, 900);
      },
    ),
  );
  testWidgets(
    'add recent',
    (t) => _shot(
      t,
      _add,
      'nut_add_recent',
      seed: true,
      then: (t) => _tap(t, find.text('Recent')),
    ),
  );
  testWidgets(
    'add meals',
    (t) => _shot(
      t,
      _add,
      'nut_add_meals',
      seed: true,
      then: (t) => _tap(t, find.text('Meals')),
    ),
  );
  testWidgets(
    'add quick',
    (t) => _shot(
      t,
      _add,
      'nut_add_quick',
      then: (t) async {
        await _tap(t, find.text('Quick add'));
      },
    ),
  );
  testWidgets(
    'amount sheet',
    (t) => _shot(
      t,
      _add,
      'nut_amount_sheet',
      seed: true,
      then: (t) async {
        await _tap(t, find.text('Recent'));
        await _tap(t, find.text('Paneer'));
      },
    ),
  );
  testWidgets(
    'describe',
    (t) => _shot(
      t,
      _add,
      'nut_describe',
      seed: true,
      overrides: [
        foodTextEstimatorProvider.overrideWithValue(_FakeEstimator()),
      ],
      then: (t) async {
        await _tap(t, find.text('Describe meal'));
        await t.enterText(
          find.byKey(const Key('describe-field')),
          '150 g paneer, 2 roti and 3 idli with chutney',
        );
        await _tap(t, find.byKey(const Key('describe-parse')));
      },
    ),
  );
  testWidgets(
    'describe estimates',
    (t) => _shot(
      t,
      _add,
      'nut_describe_ai',
      seed: true,
      overrides: [
        foodTextEstimatorProvider.overrideWithValue(_FakeEstimator()),
      ],
      then: (t) async {
        await _tap(t, find.text('Describe meal'));
        await t.enterText(
          find.byKey(const Key('describe-field')),
          '150 g paneer, 2 roti and 3 idli with chutney',
        );
        await _tap(t, find.byKey(const Key('describe-parse')));
        await _tap(t, find.text('Estimate unmatched items with AI'));
        await _tap(t, find.text('Idli'));
        await t.drag(find.byType(Scrollable).last, const Offset(0, -500));
        await _pump(t, 600);
      },
    ),
  );
  testWidgets(
    'photo',
    (t) => _shot(
      t,
      _add,
      'nut_photo',
      then: (t) => _tap(t, find.text('Meal photo')),
    ),
  );
  testWidgets(
    'custom food',
    (t) => _shot(
      t,
      _add,
      'nut_custom_food',
      then: (t) => _tap(t, find.text('Create food')),
    ),
  );
  testWidgets(
    'recipe builder',
    (t) => _shot(
      t,
      _add,
      'nut_recipe',
      seed: true,
      then: (t) async {
        await _tap(t, find.text('Meals'));
        await _tap(t, find.text('New recipe'));
      },
    ),
  );
  testWidgets(
    'scanner overlay',
    (t) => _shotWidget(
      t,
      Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [Color(0xFF4A4036), Color(0xFF15120F)],
                    radius: 0.9,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: BarcodeScanOverlay(
                torchOn: false,
                onTorch: () {},
                onManual: () {},
                onClose: () {},
              ),
            ),
          ],
        ),
      ),
      'nut_scanner',
    ),
  );

  // ── History & hydration ──────────────────────────────────────────────
  testWidgets(
    'history empty',
    (t) => _shot(t, '/nutrition/history', 'nut_history_empty'),
  );
  testWidgets(
    'history seeded',
    (t) =>
        _shot(t, '/nutrition/history', 'nut_history', seed: true, scrolls: 3),
  );
  testWidgets(
    'hydration empty',
    (t) => _shot(t, '/hydration', 'nut_hydration_empty', scrolls: 1),
  );
  testWidgets(
    'hydration seeded',
    (t) => _shot(t, '/hydration', 'nut_hydration', seed: true, scrolls: 2),
  );
  testWidgets(
    'hydration light',
    (t) =>
        _shot(t, '/hydration', 'nut_hydration_light', seed: true, light: true),
  );
}
