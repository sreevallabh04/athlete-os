import 'dart:convert';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/features/nutrition/application/food_lookup_service.dart';
import 'package:athlete_os/features/nutrition/data/food_log_repository.dart';
import 'package:athlete_os/features/nutrition/data/food_repository.dart';
import 'package:athlete_os/features/nutrition/data/open_food_facts_client.dart';
import 'package:athlete_os/features/nutrition/data/recipe_repository.dart';
import 'package:athlete_os/features/nutrition/data/saved_meal_repository.dart';
import 'package:athlete_os/features/nutrition/domain/csv_export.dart';
import 'package:athlete_os/features/nutrition/data/mappers.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/test_app.dart';

final now = DateTime(2026, 10, 25, 13, 30);
const today = '2026-10-25';
const yesterday = '2026-10-24';

FoodDraft paneerDraft({String? barcode}) => FoodDraft(
  name: 'Paneer',
  brand: 'Amul',
  barcode: barcode,
  basis: ServingBasis.per100g(
    const Nutrients(calories: 265, protein: 18.3, carbs: 1.2, fat: 20.8),
  ),
  source: FoodSources.custom,
  verification: Verifications.userEntered,
);

void main() {
  late AppDatabase db;
  late FoodRepository foods;
  late FoodLogRepository log;
  const clock = FixedClock.new;

  setUp(() {
    db = newTestDb();
    foods = FoodRepository(db, clock(now));
    log = FoodLogRepository(db, clock(now));
  });
  tearDown(() => db.close());

  group('FoodRepository', () {
    test(
      'create, search (case-insensitive), barcode, favorite, delete',
      () async {
        final p = await foods.create(paneerDraft(barcode: '8901262150019'));
        await foods.create(
          FoodDraft(
            name: 'Basmati rice, cooked',
            basis: ServingBasis.per100g(
              const Nutrients(calories: 130, protein: 2.7, carbs: 28, fat: 0.3),
            ),
            source: FoodSources.usda,
            verification: Verifications.database,
          ),
        );
        expect((await foods.search('PANEER')).single.id, p.id);
        expect((await foods.search('amul')).single.id, p.id);
        expect(await foods.search('100%'), isEmpty);
        expect((await foods.byBarcode('8901262150019'))!.id, p.id);

        await foods.setFavorite(p.id, true);
        expect((await foods.watchFavorites().first).single.name, 'Paneer');

        await foods.softDelete(p.id);
        expect(await foods.search('paneer'), isEmpty);
        expect(await foods.byBarcode('8901262150019'), isNull);
        expect((await foods.all()).map((f) => f.name), [
          'Basmati rice, cooked',
        ]);
      },
    );

    test(
      'saveCandidate preserves raw source values and is idempotent',
      () async {
        final c = OpenFoodFactsClient.mapProduct({
          'code': '8901262150019',
          'product_name': 'Malai Paneer',
          'serving_quantity': 50,
          'nutriments': {
            'energy-kcal_100g': 288,
            'proteins_100g': 18.9,
            'carbohydrates_100g': 2.3,
            'fat_100g': 22.8,
          },
        })!;
        final a = await foods.saveCandidate(
          c,
          verification: Verifications.verifiedLabel,
        );
        final b = await foods.saveCandidate(
          c,
          verification: Verifications.verifiedLabel,
        );
        expect(a.id, b.id);
        expect((await foods.all()), hasLength(1));
        expect(a.verification, Verifications.verifiedLabel);
        expect(a.calories, 144);
        final raw = jsonDecode(a.rawJson!) as Map<String, dynamic>;
        expect(raw['nutriments']['energy-kcal_100g'], 288);
        expect(raw['code'], '8901262150019');
      },
    );

    test('saveCandidate rejects incomplete data', () async {
      final c = OpenFoodFactsClient.mapProduct({
        'code': '1234567',
        'product_name': 'Mystery',
        'nutriments': {'energy-kcal_100g': 100},
      })!;
      expect(
        () => foods.saveCandidate(c, verification: Verifications.database),
        throwsStateError,
      );
    });

    test('recents are distinct and most-recent first', () async {
      final p = await foods.create(paneerDraft());
      final r = await foods.create(
        FoodDraft(
          name: 'Rice',
          basis: ServingBasis.per100g(const Nutrients(calories: 130)),
          source: FoodSources.custom,
          verification: Verifications.userEntered,
        ),
      );
      final early = FoodLogRepository(
        db,
        FixedClock(DateTime(2026, 10, 25, 8)),
      );
      await early.logFood(
        p,
        amount: const Amount.grams(100),
        mealType: MealType.breakfast,
        localDate: today,
      );
      await early.logFood(
        r,
        amount: const Amount.grams(100),
        mealType: MealType.breakfast,
        localDate: today,
      );
      await log.logFood(
        p,
        amount: const Amount.grams(50),
        mealType: MealType.lunch,
        localDate: today,
      );
      final rec = await foods.recents();
      expect(rec.map((f) => f.name).toList(), ['Paneer', 'Rice']);
    });
  });

  group('FoodLogRepository', () {
    test('logging stores a rounded nutrient snapshot + provenance', () async {
      final p = await foods.create(paneerDraft());
      final id = await log.logFood(
        p,
        amount: const Amount.grams(150),
        mealType: MealType.lunch,
        localDate: today,
      );
      final e = (await log.get(id))!;
      expect(e.calories, 397.5);
      expect(e.proteinG, 27.5); // 27.45 rounded
      expect(e.grams, 150);
      expect(e.servings, 1.5);
      expect(e.source, FoodSources.custom);
      expect(e.verification, Verifications.userEntered);
      expect(e.localDate, today);
      expect(e.tzName, isNotEmpty);

      // Editing the food later does not rewrite history.
      await foods.update(
        p.id,
        FoodDraft(
          name: 'Paneer',
          basis: ServingBasis.per100g(const Nutrients(calories: 999)),
          source: FoodSources.custom,
          verification: Verifications.userEntered,
        ),
      );
      expect((await log.get(id))!.calories, 397.5);
    });

    test('back-dated entries keep the chosen local date', () async {
      final id = await log.quickAdd(
        name: '',
        nutrients: const Nutrients(calories: 500),
        mealType: MealType.dinner,
        localDate: yesterday,
      );
      final e = (await log.get(id))!;
      expect(e.localDate, yesterday);
      expect(LocalDates.key(e.loggedAt), yesterday);
      expect(e.name, 'Quick add');
      expect(e.verification, Verifications.estimate);
      expect(e.source, FoodSources.quickAdd);
    });

    test('quick add marked exact is user_entered', () async {
      final id = await log.quickAdd(
        name: 'Thali',
        nutrients: const Nutrients(calories: 700),
        mealType: MealType.lunch,
        localDate: today,
        isEstimate: false,
      );
      expect((await log.get(id))!.verification, Verifications.userEntered);
    });

    test(
      'soft delete excludes from day/range; restore brings it back',
      () async {
        final id = await log.quickAdd(
          name: 'Snack',
          nutrients: const Nutrients(calories: 200),
          mealType: MealType.snack,
          localDate: today,
        );
        expect(await log.day(today), hasLength(1));
        await log.softDelete(id);
        expect(await log.day(today), isEmpty);
        expect(await log.range(yesterday, today), isEmpty);
        expect((await log.get(id))!.deletedAt, isNotNull);
        await log.restore(id);
        expect(await log.day(today), hasLength(1));
      },
    );

    test('edit rescales the snapshot proportionally and moves meal', () async {
      final p = await foods.create(paneerDraft());
      final id = await log.logFood(
        p,
        amount: const Amount.grams(100),
        mealType: MealType.lunch,
        localDate: today,
      );
      await log.updateEntry(id, servings: 2, mealType: MealType.dinner);
      final e = (await log.get(id))!;
      expect(e.calories, 530);
      expect(e.grams, 200);
      expect(e.mealType, 'dinner');
      expect(() => log.updateEntry(id, servings: 0), throwsArgumentError);
    });

    test('copy a meal and a whole day from a previous date', () async {
      final p = await foods.create(paneerDraft());
      await log.logFood(
        p,
        amount: const Amount.grams(100),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      await log.quickAdd(
        name: 'Chai',
        nutrients: const Nutrients(calories: 80),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      final deleted = await log.quickAdd(
        name: 'Deleted',
        nutrients: const Nutrients(calories: 1000),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      await log.softDelete(deleted);
      await log.quickAdd(
        name: 'Dinner',
        nutrients: const Nutrients(calories: 600),
        mealType: MealType.dinner,
        localDate: yesterday,
      );

      final n = await log.copy(
        fromDate: yesterday,
        toDate: today,
        fromMeal: MealType.breakfast,
        toMeal: MealType.breakfast,
      );
      expect(n, 2);
      final todays = await log.day(today);
      expect(todays.map((e) => e.name).toSet(), {'Paneer', 'Chai'});
      expect(todays.every((e) => e.localDate == today), isTrue);
      expect(
        todays.firstWhere((e) => e.name == 'Chai').verification,
        Verifications.estimate,
      );

      final all = await log.copy(fromDate: yesterday, toDate: '2026-10-26');
      expect(all, 3);
      expect(await log.copy(fromDate: '2020-01-01', toDate: today), 0);
    });

    test('range query and CSV export', () async {
      await log.quickAdd(
        name: 'Poha, with "peanuts"',
        nutrients: const Nutrients(calories: 350, protein: 8),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      await log.quickAdd(
        name: '=cmd',
        nutrients: const Nutrients(calories: 100),
        mealType: MealType.snack,
        localDate: today,
      );
      final rows = await log.range(yesterday, today);
      expect(rows, hasLength(2));
      final csv = buildFoodLogCsv(rows.map((e) => e.csvRow));
      final lines = csv.trim().split('\r\n');
      expect(lines.first, startsWith('date,logged_at_utc,meal,food'));
      expect(lines[1], contains('"Poha, with ""peanuts"""'));
      expect(lines[1], contains('350'));
      expect(lines[2], contains("'=cmd"));
    });
  });

  group('RecipeRepository', () {
    test('per-serving nutrition and logging a recipe', () async {
      final recipes = RecipeRepository(db, clock(now));
      final p = await foods.create(paneerDraft());
      final rice = await foods.create(
        FoodDraft(
          name: 'Rice',
          basis: ServingBasis.per100g(
            const Nutrients(calories: 130, protein: 2.7, carbs: 28, fat: 0.3),
          ),
          source: FoodSources.usda,
          verification: Verifications.database,
        ),
      );
      final id = await recipes.create(
        name: 'Paneer rice bowl',
        servings: 2,
        ingredients: [
          IngredientDraft.fromFood(p, const Amount.grams(200)),
          IngredientDraft.fromFood(rice, const Amount.grams(300)),
        ],
      );
      final r = (await recipes.get(id))!;
      expect(r.ingredients, hasLength(2));
      expect(r.total.calories, 530 + 390);
      expect(r.perServing.calories, 460);
      expect(r.perServing.protein, closeTo((36.6 + 8.1) / 2, 1e-9));
      expect(r.verification, Verifications.userEntered); // weakest wins

      final entryId = await recipes.logRecipe(
        log,
        id,
        servings: 1.5,
        mealType: MealType.dinner,
        localDate: today,
      );
      final e = (await log.get(entryId))!;
      expect(e.calories, 690);
      expect(e.recipeId, id);
      expect(e.source, FoodSources.recipe);

      // Update replaces ingredients.
      await recipes.update(
        id,
        name: 'Paneer bowl',
        servings: 1,
        ingredients: [IngredientDraft.fromFood(p, const Amount.grams(100))],
      );
      final u = (await recipes.get(id))!;
      expect(u.ingredients, hasLength(1));
      expect(u.perServing.calories, 265);

      await recipes.softDelete(id);
      expect(await recipes.all(), isEmpty);
    });

    test('validation', () async {
      final recipes = RecipeRepository(db, clock(now));
      expect(
        () => recipes.create(name: 'x', servings: 0, ingredients: const []),
        throwsArgumentError,
      );
      expect(
        () => recipes.create(name: 'x', servings: 1, ingredients: const []),
        throwsArgumentError,
      );
    });
  });

  group('SavedMealRepository', () {
    test('template from logged meal, log in one tap', () async {
      final saved = SavedMealRepository(db, clock(now));
      final p = await foods.create(paneerDraft());
      await log.logFood(
        p,
        amount: const Amount.grams(100),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      await log.quickAdd(
        name: 'Chai',
        nutrients: const Nutrients(calories: 80),
        mealType: MealType.breakfast,
        localDate: yesterday,
      );
      final id = await saved.createFromEntries(
        'Usual breakfast',
        await log.day(yesterday),
        mealType: MealType.breakfast,
      );
      final m = (await saved.get(id))!;
      expect(m.items, hasLength(2));
      expect(m.total.calories, 345);
      expect(m.hasEstimates, isTrue);

      final ids = await saved.logSavedMeal(
        log,
        id,
        mealType: MealType.breakfast,
        localDate: today,
      );
      expect(ids, hasLength(2));
      final todays = await log.day(today);
      expect(todays.fold<double>(0, (a, e) => a + e.calories), 345);
      final paneer = todays.firstWhere((e) => e.name == 'Paneer');
      expect(paneer.source, FoodSources.custom);
      expect(paneer.foodId, p.id);

      await saved.softDelete(id);
      expect(await saved.all(), isEmpty);
    });
  });

  group('FoodLookupService', () {
    test('local-first barcode, then OFF, and honest status', () async {
      var calls = 0;
      final off = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'status': 'failure',
              'result': {'id': 'product_not_found'},
            }),
            404,
          );
        }),
        sleep: (_) async {},
      );
      final status = IntegrationStatusRepository(db);
      final svc = FoodLookupService(
        foods: foods,
        off: off,
        usda: null,
        status: status,
      );
      await foods.create(paneerDraft(barcode: '8901262150019'));
      final local = await svc.lookupBarcode('8901262150019');
      expect(local, isA<BarcodeLocalHit>());
      expect(calls, 0);

      final missing = await svc.lookupBarcode('0000000000000');
      expect(missing, isA<BarcodeNotFound>());
      expect(calls, 1);
      expect(
        (await status.get(Providers.openFoodFacts))!.status,
        ConnectionStates.connected,
      );

      final search = await svc.searchRemote('paneer');
      expect(search.usdaConfigured, isFalse);
      expect(search.usda, isEmpty);
    });

    test('server errors are recorded as errors, offline is not', () async {
      final status = IntegrationStatusRepository(db);
      final svc = FoodLookupService(
        foods: foods,
        off: OpenFoodFactsClient(
          client: MockClient((_) async => http.Response('x', 500)),
          sleep: (_) async {},
        ),
        usda: null,
        status: status,
      );
      final r = await svc.lookupBarcode('8901262150019');
      expect(r, isA<BarcodeLookupFailed>());
      expect(
        (await status.get(Providers.openFoodFacts))!.status,
        ConnectionStates.error,
      );
      final s = await svc.searchRemote('dal');
      expect(s.errors.single, startsWith('Open Food Facts:'));
    });
  });
}
