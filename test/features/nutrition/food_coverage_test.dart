import 'dart:convert';
import 'dart:typed_data';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/food_lookup_service.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/data/food_repository.dart';
import 'package:athlete_os/features/nutrition/data/indian_food_db.dart';
import 'package:athlete_os/features/nutrition/data/label_photo.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:athlete_os/features/nutrition/domain/nutrition_label.dart';
import 'package:athlete_os/features/nutrition/presentation/ai_food_log_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/custom_food_screen.dart';
import 'package:athlete_os/features/nutrition/presentation/food_actions.dart';
import 'package:athlete_os/features/nutrition/presentation/food_search_panel.dart';
import 'package:athlete_os/features/nutrition/presentation/label_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import '../../golden_path/golden_helpers.dart';
import '../../helpers/test_app.dart';

const _code = '8901088000000';

/// A transcribed two-column label (values made up for the test).
const labelArgs = <String, dynamic>{
  'product_name': 'Saffola High Protein Oats',
  'brand': 'Saffola',
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
};

class FakeLabelReader implements NutritionLabelReader {
  FakeLabelReader({this.configured = true, this.args = labelArgs});
  final bool configured;
  final Map<String, dynamic> args;
  var calls = 0;

  @override
  bool get isConfigured => configured;

  @override
  Future<LabelReadResult> read(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  }) async {
    calls++;
    if (!configured) {
      return const LabelReadUnavailable(labelReaderNotConfiguredMessage);
    }
    return LabelReadSuccess(parseNutritionLabel(args), provider: 'gemini');
  }
}

final Uint8List tinyJpeg = img.encodeJpg(img.Image(width: 6, height: 8));

/// Fake food APIs: OFF knows nothing (or is down), USDA has no results.
MockClient fakeApis(List<Uri> calls, {bool offDown = false}) =>
    MockClient((req) async {
      calls.add(req.url);
      final json = {'content-type': 'application/json'};
      if (req.url.host == 'api.nal.usda.gov') {
        return http.Response(jsonEncode({'foods': []}), 200, headers: json);
      }
      if (req.url.path.startsWith('/api/v3/product/')) {
        return http.Response(
          jsonEncode({
            'status': 'failure',
            'result': {'id': 'product_not_found'},
          }),
          404,
          headers: json,
        );
      }
      if (offDown) return http.Response('down', 503);
      if (req.url.host == 'search.openfoodfacts.org') {
        return http.Response(jsonEncode({'hits': []}), 200, headers: json);
      }
      return http.Response(jsonEncode({'products': []}), 200, headers: json);
    });

List<Override> coverageOverrides({
  required List<Uri> calls,
  FakeLabelReader? reader,
  bool offDown = false,
}) => [
  nutritionHttpClientProvider.overrideWithValue(
    fakeApis(calls, offDown: offDown),
  ),
  nutritionLabelReaderProvider.overrideWithValue(reader ?? FakeLabelReader()),
  labelPhotoPickerProvider.overrideWithValue((_) async => LabelPhoto(tinyJpeg)),
  aiPhotoConsentProvider.overrideWith((ref) => Stream.value(true)),
  // Deterministic: no Indian Food DB rows here (own tests elsewhere).
  indianFoodDbProvider.overrideWithValue(IndianFoodDb.fromCsv('Dish Name')),
];

/// A launcher page so the screen under test can pop a result.
class _Launcher extends ConsumerWidget {
  const _Launcher(this.onPressed);
  final Future<void> Function(BuildContext context, WidgetRef ref) onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => onPressed(context, ref),
        child: const Text('GO'),
      ),
    ),
  );
}

Future<T> settle<T>(WidgetTester tester, Future<T> future) async {
  T? value;
  Object? error;
  var done = false;
  // ignore: unawaited_futures
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 100 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (error != null) throw error!;
  expect(done, isTrue, reason: 'future never completed');
  return value as T;
}

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  group('local-first search', () {
    test('word-order and brand-insensitive matching', () async {
      final repo = FoodRepository(db, FixedClock(goldenNow));
      FoodDraft d(String name, {String? brand}) => FoodDraft(
        name: name,
        brand: brand,
        basis: ServingBasis.per100g(
          const Nutrients(calories: 380, protein: 25, carbs: 55, fat: 6.5),
        ),
        source: FoodSources.custom,
        verification: Verifications.userEntered,
      );
      await repo.create(d('Saffola High Protein Oats', brand: 'Saffola'));
      await repo.create(d('High Protein Oats', brand: 'Saffola'));
      await repo.create(d('Rolled oats', brand: 'Quaker'));

      final r1 = await repo.search('saffola protein oats');
      expect(r1.map((f) => f.name), [
        'High Protein Oats',
        'Saffola High Protein Oats',
      ]);
      // Whole-phrase name matches rank first.
      final r2 = await repo.search('SAFFOLA HIGH PROTEIN OATS');
      expect(r2.first.name, 'Saffola High Protein Oats');
      expect(r2, hasLength(2));
      expect((await repo.search('oats saffola')), hasLength(2));
      expect((await repo.search('oats')), hasLength(3));
      expect(await repo.search('muesli'), isEmpty);
    });
  });

  group('label scan', () {
    Future<ProviderContainer> openScan(
      WidgetTester tester, {
      FakeLabelReader? reader,
      List<Uri>? calls,
    }) async {
      useTallView(tester);
      final container = goldenContainer(
        db,
        extra: coverageOverrides(calls: calls ?? [], reader: reader),
      );
      await tester.pumpWidget(
        hostIn(
          container,
          _Launcher(
            (context, ref) => openLabelScan(
              context,
              name: 'saffola high protein oats',
              barcode: _code,
              meal: MealType.breakfast,
              date: goldenToday,
            ),
          ),
        ),
      );
      await tester.tap(find.text('GO'));
      await pumpUntil(tester, find.byType(LabelScanScreen));
      await pumpFrames(tester, count: 3);
      return container;
    }

    Future<void> readLabel(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('label-take-photo')));
      await pumpUntil(tester, find.text('Check label values'));
      await pumpFrames(tester, count: 2);
    }

    String field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    testWidgets('reading fills the review form, flags unreadable values and '
        'saves to My foods as user_entered', (tester) async {
      final reader = FakeLabelReader();
      final container = await openScan(tester, reader: reader);
      expect(find.text('saffola high protein oats'), findsWidgets);
      await readLabel(tester);
      expect(reader.calls, 1);

      expect(field(tester, 'label-name'), 'Saffola High Protein Oats');
      expect(field(tester, 'label-brand'), 'Saffola');
      expect(field(tester, 'label-barcode'), _code);
      expect(field(tester, 'label-per_100g.kcal'), '380');
      expect(field(tester, 'label-per_100g.fat_g'), '6.5');
      expect(field(tester, 'label-per_100g.fiber_g'), '');
      expect(field(tester, 'label-serving.size_g'), '40');
      expect(field(tester, 'label-serving.kcal'), '152');
      // Unreadable fibre is flagged in both columns, never guessed.
      expect(find.text('Check on pack'), findsNWidgets(2));
      expect(find.textContaining('Dietary fibre (per 100 g)'), findsOneWidget);
      expect(
        find.textContaining('% off'),
        findsNothing,
      ); // 380 ≈ 4·25+4·55+9·6.5

      // A typo the user would see flagged by the energy check.
      await tester.enterText(
        find.byKey(const Key('label-per_100g.kcal')),
        '280',
      );
      await tester.pump();
      expect(find.textContaining('% off'), findsWidgets);
      await tester.enterText(
        find.byKey(const Key('label-per_100g.kcal')),
        '380',
      );
      await tester.pump(); // the warning goes away; layout shifts back
      expect(find.textContaining('% off'), findsNothing);
      // The user types the fibre value the AI could not read.
      await tester.enterText(
        find.byKey(const Key('label-per_100g.fiber_g')),
        '9',
      );
      await tester.pump();
      expect(field(tester, 'label-per_100g.fiber_g'), '9');
      expect(field(tester, 'label-per_100g.kcal'), '380');

      await tester.tap(find.byKey(const Key('label-save')));
      await pumpUntil(tester, find.text('GO'));
      await pumpFrames(tester, count: 2);

      final foods = await settle(tester, db.select(db.foods).get());
      expect(foods, hasLength(1));
      final f = foods.single;
      expect(f.name, 'Saffola High Protein Oats');
      expect(f.brand, 'Saffola');
      expect(f.barcode, _code);
      expect(f.source, FoodSources.custom);
      expect(f.verification, Verifications.userEntered);
      expect(f.servingSize, 40);
      expect(f.servingUnit, 'g');
      expect(f.gramsPerServing, 40);
      expect(f.calories, 152);
      expect(f.proteinG, 10);
      expect(f.fiberG, closeTo(3.6, 1e-9));
      final raw = jsonDecode(f.rawJson!) as Map<String, Object?>;
      expect(raw['provider'], 'nutrition_label_photo');
      expect(raw['confirmed_by_user'], isTrue);
      expect((raw['ai_extraction']! as Map)['brand'], 'Saffola');
      expect(raw['edited_fields'], contains('per_100g.fiber_g'));
      expect(raw['ai_provider'], 'gemini');
      expect(await settle(tester, db.select(db.foodLogEntries).get()), isEmpty);

      // Local-first: searching finds it instantly, no network.
      final hits = await settle(
        tester,
        container.read(foodRepositoryProvider).search('saffola protein oats'),
      );
      expect(hits.single.id, f.id);
      await driftTeardown(tester);
    });

    testWidgets('Save & log now writes the food and a breakfast entry', (
      tester,
    ) async {
      await openScan(tester);
      await readLabel(tester);
      expect(find.text('Save & log to Breakfast'), findsOneWidget);
      await tester.tap(find.byKey(const Key('label-save-log')));
      await pumpUntil(tester, find.text('Log to Breakfast'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Log to Breakfast'));
      await pumpUntil(tester, find.text('GO'));
      await pumpFrames(tester, count: 2);

      final foods = await settle(tester, db.select(db.foods).get());
      final entries = await settle(tester, db.select(db.foodLogEntries).get());
      expect(foods, hasLength(1));
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.foodId, foods.single.id);
      expect(e.mealType, 'breakfast');
      expect(e.localDate, goldenToday);
      expect(e.calories, 152); // 1 serving (40 g)
      expect(e.verification, Verifications.userEntered);
      await driftTeardown(tester);
    });

    testWidgets('AI unavailable → manual custom-food form, prefilled', (
      tester,
    ) async {
      final reader = FakeLabelReader(configured: false);
      await openScan(tester, reader: reader);
      expect(find.text(labelReaderNotConfiguredMessage), findsOneWidget);
      expect(find.byKey(const Key('label-take-photo')), findsNothing);
      await tester.tap(find.text('Type label values'));
      await pumpUntil(tester, find.byType(CustomFoodScreen));
      await pumpFrames(tester, count: 2);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('food-name')))
            .controller!
            .text,
        'saffola high protein oats',
      );
      expect(
        tester.widget<CustomFoodScreen>(find.byType(CustomFoodScreen)).barcode,
        _code,
      );
      expect(reader.calls, 0);
      await driftTeardown(tester);
    });
  });

  group("search: Can't find it?", () {
    Future<ProviderContainer> search(
      WidgetTester tester, {
      bool offDown = false,
    }) async {
      useTallView(tester);
      final calls = <Uri>[];
      final container = goldenContainer(
        db,
        extra: coverageOverrides(calls: calls, offDown: offDown),
      );
      await tester.pumpWidget(
        hostIn(
          container,
          const Scaffold(
            body: FoodSearchPanel(meal: MealType.breakfast, date: goldenToday),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('food-search-field')),
        'Saffola High Protein Oats',
      );
      await tester.pump(const Duration(milliseconds: 900));
      // Compact panel is there before searching too.
      expect(find.text("CAN'T FIND IT?"), findsOneWidget);
      expect(
        find.text('Search Open Food Facts for "Saffola High Protein Oats"'),
        findsOneWidget,
      );
      // Remote search runs on explicit submit (keyboard search action).
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(
        tester,
        find.text('Can\'t find "Saffola High Protein Oats"?'),
      );
      await pumpFrames(tester, count: 2);
      return container;
    }

    void back(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();

    testWidgets('0 results → prominent panel; each action routes correctly', (
      tester,
    ) async {
      await search(tester);
      expect(find.byKey(const Key('cantfind-label')), findsOneWidget);

      await tester.tap(find.byKey(const Key('cantfind-label')));
      await pumpUntil(tester, find.byType(LabelScanScreen));
      final scan = tester.widget<LabelScanScreen>(find.byType(LabelScanScreen));
      expect(scan.initialName, 'Saffola High Protein Oats');
      expect(scan.meal, MealType.breakfast);
      expect(scan.date, goldenToday);
      back(tester);
      await pumpFrames(tester, count: 3);

      await tester.tap(find.byKey(const Key('cantfind-manual')));
      await pumpUntil(tester, find.byType(CustomFoodScreen));
      expect(
        tester
            .widget<CustomFoodScreen>(find.byType(CustomFoodScreen))
            .initialName,
        'Saffola High Protein Oats',
      );
      back(tester);
      await pumpFrames(tester, count: 3);

      await tester.tap(find.byKey(const Key('cantfind-ai')));
      await pumpUntil(tester, find.byType(AiFoodLogScreen));
      final ai = tester.widget<AiFoodLogScreen>(find.byType(AiFoodLogScreen));
      expect(ai.initialText, 'Breakfast: Saffola High Protein Oats');
      expect(ai.initialDate, goldenToday);
      await driftTeardown(tester);
    });

    testWidgets('OFF down everywhere → one compact notice + the panel', (
      tester,
    ) async {
      await search(tester, offDown: true);
      expect(
        find.textContaining('Open Food Facts search is down'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('cantfind-label')), findsOneWidget);
      await driftTeardown(tester);
    });
  });

  testWidgets('barcode not found → scan label with the barcode → the next '
      'lookup resolves locally without the network', (tester) async {
    useTallView(tester);
    final calls = <Uri>[];
    final container = goldenContainer(
      db,
      extra: coverageOverrides(calls: calls),
    );
    await tester.pumpWidget(
      hostIn(
        container,
        _Launcher(
          (context, ref) => lookupAndLogBarcode(
            context,
            ref,
            code: _code,
            meal: MealType.breakfast,
            date: goldenToday,
          ),
        ),
      ),
    );
    await tester.tap(find.text('GO'));
    await pumpUntil(tester, find.text('Product not found'));
    expect(calls.where((u) => u.path.contains(_code)), hasLength(1));
    await tester.tap(find.byKey(const Key('barcode-scan-label')));
    await pumpUntil(tester, find.byType(LabelScanScreen));
    expect(
      tester.widget<LabelScanScreen>(find.byType(LabelScanScreen)).barcode,
      _code,
    );
    await pumpFrames(tester, count: 2);
    await tester.tap(find.byKey(const Key('label-take-photo')));
    await pumpUntil(tester, find.text('Check label values'));
    await pumpFrames(tester, count: 2);
    await tester.tap(find.byKey(const Key('label-save')));
    await pumpUntil(tester, find.text('GO'));
    await pumpFrames(tester, count: 2);

    final before = calls.length;
    final result = await settle(
      tester,
      container.read(foodLookupServiceProvider).lookupBarcode(_code),
    );
    expect(result, isA<BarcodeLocalHit>());
    expect((result as BarcodeLocalHit).food.name, 'Saffola High Protein Oats');
    expect(calls.length, before); // resolved locally
    await driftTeardown(tester);
  });
}
