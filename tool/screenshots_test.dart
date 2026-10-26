// Visual QA: renders real routes of the app (real router, in-memory DB,
// bundled fonts) at the reference phone size (1080×2400 px, DPR 2.75) and
// writes PNGs to build/shots/.
//
//   flutter test tool/screenshots_test.dart                 # all shots
//   flutter test tool/screenshots_test.dart --plain-name today
//   flutter test tool/screenshots_test.dart --dart-define=SHOT_ROUTE=/settings
//
// Add your own: call `shotRoute(tester, '/your/route', 'name')` inside a
// `testWidgets`, or pass SHOT_ROUTE (+ optional SHOT_NAME, SHOT_LIGHT=true,
// SHOT_SCROLLS=2) on the command line.
//
// Notes
// * GPU shaders are disabled under `flutter test`, so the HUD background and
//   orb render their painter fallbacks (which are designed to look right).
// * Time is fixed to 2026-10-25 21:40 (local) unless you pass `now:`.
// * View the PNGs with any image viewer (or the Read tool in an agent).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/boot/boot_sequence.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/data/indian_food_db.dart';
import 'package:athlete_os/features/nutrition/data/label_photo.dart';
import 'package:athlete_os/features/nutrition/domain/nutrition_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import '../test/helpers/test_app.dart';

/// Output root; `--dart-define=SHOT_DIR=build/shots/qa` redirects a run.
const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: 'build/shots');
const _outDir = shotDir;

/// Reference device: OPPO CPH2251, 1080×2400, DPR 2.75.
const shotPhysicalSize = Size(1080, 2400);
const shotDpr = 2.75;

bool _fontsLoaded = false;

/// Registers the bundled fonts + Material icons so text isn't drawn as
/// Ahem boxes. Safe to call repeatedly.
Future<void> loadShotFonts() async {
  if (_fontsLoaded) return;
  // Synchronous reads: async file IO never completes inside the fake-async
  // zone of a widget test.
  Future<ByteData> bytes(String path) =>
      Future.value(ByteData.view(File(path).readAsBytesSync().buffer));
  const families = {
    'Inter': ['Regular', 'Medium', 'SemiBold', 'Bold'],
    'InterDisplay': ['SemiBold', 'Bold', 'ExtraBold'],
    'Rajdhani': ['Medium', 'SemiBold', 'Bold'],
    'JetBrainsMono': ['Regular', 'SemiBold'],
  };
  for (final e in families.entries) {
    final loader = FontLoader(e.key);
    for (final w in e.value) {
      loader.addFont(bytes('assets/fonts/${e.key}-$w.ttf'));
    }
    await loader.load();
  }
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(bytes(icons.path))).load();
  }
  _fontsLoaded = true;
}

/// Pumps the real app at [path] and saves `build/shots/<name>.png`.
///
/// * [scrolls]: additional shots after scrolling down by ~80 % of a screen
///   each (`<name>_1.png`, `<name>_2.png`…).
/// * [light]: use the light theme.
/// * [settle]: time to let data load and entrance animations finish.
/// * [overrides]: extra provider overrides (seed data, fake services…).
/// * [prepare]: runs after the first frame (e.g. seed the DB, tap things).
Future<void> shotRoute(
  WidgetTester tester,
  String path,
  String name, {
  int scrolls = 0,
  bool light = false,
  Duration settle = const Duration(milliseconds: 1800),
  DateTime? now,
  List<Override> overrides = const [],
  Future<void> Function(WidgetTester tester)? prepare,
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
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          ...testOverrides(db, now: now ?? DateTime(2026, 10, 25, 21, 40)),
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
  if (prepare != null) await prepare(tester);
  await _advance(tester, settle);
  await _capture(tester, key, name);

  for (var i = 1; i <= scrolls; i++) {
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) break;
    await tester.drag(
      scrollable.first,
      Offset(0, -shotPhysicalSize.height / shotDpr * 0.8),
    );
    await _advance(tester, const Duration(milliseconds: 1200));
    await _capture(tester, key, '${name}_$i');
  }

  // Let drift stream timers settle before teardown.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  await db.close();
}

Future<void> _advance(WidgetTester tester, Duration d) async {
  final steps = (d.inMilliseconds / 50).ceil();
  for (var i = 0; i < steps; i++) {
    // Let real async work (DB queries) complete between frames.
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
    final file = File('$_outDir/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
  // ignore: avoid_print
  print('shot → $_outDir/$name.png');
}

/// OFF/USDA that know nothing (search-a-licious `hits: []`).
MockClient _emptyFoodApis() => MockClient((req) async {
  final body = req.url.host == 'api.nal.usda.gov'
      ? {'foods': []}
      : req.url.host == 'search.openfoodfacts.org'
      ? {'hits': []}
      : {'products': []};
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
});

/// Example extraction (made-up values) with one unreadable field.
class _FakeLabelReader implements NutritionLabelReader {
  @override
  bool get isConfigured => true;

  @override
  Future<LabelReadResult> read(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  }) async => LabelReadSuccess(
    parseNutritionLabel({
      'product_name': 'Example Protein Oats',
      'brand': 'Example',
      'basis': 'both',
      'unit': 'g',
      'per_100g': {
        'kcal': 380,
        'protein_g': 25,
        'carbs_g': 55,
        'fat_g': 6.5,
        'sugar_g': 1.2,
      },
      'serving': {
        'size_g': 40,
        'kcal': 152,
        'protein_g': 10,
        'carbs_g': 22,
        'fat_g': 2.6,
      },
      'confidence': 0.86,
      'unreadable_fields': ['per_100g.fiber_g', 'serving.fiber_g'],
    }),
    provider: 'gemini',
  );
}

/// A label-like JPEG for the thumbnail.
Future<Uint8List> _fakeLabelPhoto() async {
  final image = img.Image(width: 360, height: 480)
    ..clear(img.ColorRgb8(244, 241, 232));
  const lines = [
    'NUTRITION INFORMATION',
    '              per 100g  per 40g',
    'Energy (kcal)    380      152',
    'Protein (g)       25       10',
    'Total Carb. (g)   55       22',
    'Total Sugars (g) 1.2      0.5',
    'Total Fat (g)    6.5      2.6',
    'Dietary Fibre (g)  -        -',
  ];
  for (var i = 0; i < lines.length; i++) {
    img.drawString(
      image,
      lines[i],
      font: img.arial14,
      x: 16,
      y: 24 + i * 34,
      color: img.ColorRgb8(20, 20, 20),
    );
  }
  img.drawLine(
    image,
    x1: 12,
    y1: 50,
    x2: 348,
    y2: 50,
    color: img.ColorRgb8(20, 20, 20),
    thickness: 2,
  );
  return img.encodeJpg(image, quality: 85);
}

void main() {
  setUpAll(loadShotFonts);

  const route = String.fromEnvironment('SHOT_ROUTE');
  if (route.isNotEmpty) {
    testWidgets('shot $route', (tester) async {
      await shotRoute(
        tester,
        route,
        const String.fromEnvironment('SHOT_NAME', defaultValue: 'custom'),
        light: const bool.fromEnvironment('SHOT_LIGHT'),
        scrolls: const int.fromEnvironment('SHOT_SCROLLS'),
      );
    });
    return;
  }

  testWidgets(
    'today',
    (t) => shotRoute(t, AppPaths.today, 'today', scrolls: 2),
  );
  testWidgets(
    'train',
    (t) => shotRoute(t, AppPaths.train, 'train', scrolls: 1),
  );
  testWidgets(
    'nutrition',
    (t) => shotRoute(t, AppPaths.nutrition, 'nutrition', scrolls: 1),
  );
  testWidgets('coach', (t) => shotRoute(t, AppPaths.coach, 'coach'));
  testWidgets('life', (t) => shotRoute(t, AppPaths.life, 'life', scrolls: 1));
  testWidgets('settings', (t) => shotRoute(t, AppPaths.settings, 'settings'));
  testWidgets(
    'gallery',
    (t) => shotRoute(t, AppPaths.devGallery, 'gallery', scrolls: 7),
  );
  testWidgets(
    'today light',
    (t) => shotRoute(t, AppPaths.today, 'today_light', light: true),
  );
  testWidgets(
    'gallery light',
    (t) => shotRoute(
      t,
      AppPaths.devGallery,
      'gallery_light',
      light: true,
      scrolls: 2,
    ),
  );
  // Food coverage: "Can't find it?" after a search with no results, and the
  // nutrition-label review with a fake AI extraction (example values).
  testWidgets('food-cov indian', (t) async {
    final indian = IndianFoodDb.fromCsv(
      File(indianFoodCsvAsset).readAsStringSync(),
    );
    await t.runAsync(indian.index);
    await shotRoute(
      t,
      '${AppPaths.addFood}?meal=lunch',
      'food-cov/search_indian',
      overrides: [indianFoodDbProvider.overrideWithValue(indian)],
      prepare: (t) async {
        await _advance(t, const Duration(milliseconds: 600));
        await t.enterText(find.byKey(const Key('food-search-field')), 'paneer');
      },
    );
  });
  testWidgets('food-cov search', (t) async {
    await shotRoute(
      t,
      '${AppPaths.addFood}?meal=breakfast',
      'food-cov/search_cantfind',
      overrides: [
        nutritionHttpClientProvider.overrideWithValue(_emptyFoodApis()),
      ],
      prepare: (t) async {
        await _advance(t, const Duration(milliseconds: 600));
        await t.enterText(
          find.byKey(const Key('food-search-field')),
          'Saffola High Protein Oats',
        );
        await t.testTextInput.receiveAction(TextInputAction.search);
      },
    );
  });
  testWidgets('food-cov label review', (t) async {
    final photo = await t.runAsync(_fakeLabelPhoto);
    await shotRoute(
      t,
      '${AppPaths.labelScan}?name=Example%20Protein%20Oats'
          '&barcode=8900000000000&meal=breakfast',
      'food-cov/label_review',
      scrolls: 1,
      overrides: [
        nutritionLabelReaderProvider.overrideWithValue(_FakeLabelReader()),
        labelPhotoPickerProvider.overrideWithValue(
          (_) async => LabelPhoto(photo!),
        ),
        aiPhotoConsentProvider.overrideWith((ref) => Stream.value(true)),
      ],
      prepare: (t) async {
        await _advance(t, const Duration(milliseconds: 600));
        await t.tap(find.byKey(const Key('label-take-photo')));
      },
    );
  });
  testWidgets('food-cov label capture', (t) async {
    await shotRoute(
      t,
      '${AppPaths.labelScan}?name=Example%20Protein%20Oats&meal=breakfast',
      'food-cov/label_capture',
      overrides: [
        nutritionLabelReaderProvider.overrideWithValue(_FakeLabelReader()),
      ],
    );
  });
  testWidgets('boot', (t) async {
    BootGate.debugReset();
    await shotRoute(
      t,
      AppPaths.today,
      'boot',
      settle: const Duration(milliseconds: 1150),
      overrides: [bootSequenceEnabledProvider.overrideWithValue(true)],
    );
  });
}
