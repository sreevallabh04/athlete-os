import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/env.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../data/food_log_repository.dart';
import '../data/food_repository.dart';
import '../data/mappers.dart';
import '../data/open_food_facts_client.dart';
import '../data/recipe_repository.dart';
import '../data/saved_meal_repository.dart';
import '../data/usda_client.dart';
import '../data/weight_query.dart';
import '../domain/ai_contracts.dart';
import '../domain/nutrition_label.dart';
import '../domain/nutrition_calc.dart';
import 'food_lookup_service.dart';

// ---------------------------------------------------------------------------
// Repositories & clients
// ---------------------------------------------------------------------------

final foodRepositoryProvider = Provider<FoodRepository>(
  (ref) =>
      FoodRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);

final foodLogRepositoryProvider = Provider<FoodLogRepository>(
  (ref) =>
      FoodLogRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);

final recipeRepositoryProvider = Provider<RecipeRepository>(
  (ref) =>
      RecipeRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);

final savedMealRepositoryProvider = Provider<SavedMealRepository>(
  (ref) => SavedMealRepository(
    ref.watch(databaseProvider),
    ref.watch(clockProvider),
  ),
);

final weightQueryProvider = Provider<WeightQuery>(
  (ref) => WeightQuery(ref.watch(databaseProvider)),
);

/// HTTP client for food databases. Overridden in tests with a MockClient.
final nutritionHttpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// Kept alive for the app lifetime so the client-side rate limits hold.
final openFoodFactsClientProvider = Provider<OpenFoodFactsClient>(
  (ref) => OpenFoodFactsClient(client: ref.watch(nutritionHttpClientProvider)),
);

/// USDA FoodData Central. Uses the personal `USDA_API_KEY` when supplied at
/// build time, otherwise USDA's public `DEMO_KEY` with a stricter limiter.
final usdaClientProvider = Provider<UsdaClient?>((ref) {
  return UsdaClient(
    client: ref.watch(nutritionHttpClientProvider),
    apiKey: Env.usdaEffectiveKey,
    demoKey: Env.usdaIsDemo,
  );
});

final foodLookupServiceProvider = Provider<FoodLookupService>(
  (ref) => FoodLookupService(
    foods: ref.watch(foodRepositoryProvider),
    off: ref.watch(openFoodFactsClientProvider),
    usda: ref.watch(usdaClientProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
  ),
);

/// AI fallback for free-text logging. The AI feature overrides this with a
/// real implementation; the default honestly reports "not configured".
final foodTextEstimatorProvider = Provider<FoodTextEstimator>(
  (ref) => const UnconfiguredFoodTextEstimator(),
);

/// Meal photo analysis. Default reports "not configured".
final mealPhotoAnalyzerProvider = Provider<MealPhotoAnalyzer>(
  (ref) => const UnconfiguredMealPhotoAnalyzer(),
);

/// Nutrition-label photo reader (transcribes, never estimates). Default
/// reports "not configured"; the AI feature overrides it.
final nutritionLabelReaderProvider = Provider<NutritionLabelReader>(
  (ref) => const UnconfiguredNutritionLabelReader(),
);

// ---------------------------------------------------------------------------
// Dates & day data
// ---------------------------------------------------------------------------

String todayKey(Ref ref) => LocalDates.key(ref.read(clockProvider).now());

/// Date shown on the Nutrition tab.
class NutritionDateNotifier extends Notifier<String> {
  @override
  String build() => ref.watch(localDayProvider);

  void set(String date) => state = date;
  void shift(int days) => state = LocalDates.addDays(state, days);
  void today() => state = LocalDates.key(ref.read(clockProvider).now());
}

final nutritionDateProvider = NotifierProvider<NutritionDateNotifier, String>(
  NutritionDateNotifier.new,
);

final dayEntriesProvider = StreamProvider.family<List<FoodLogEntry>, String>(
  (ref, date) => ref.watch(foodLogRepositoryProvider).watchDay(date),
);

/// Targets from the profile (editable examples by default).
final nutritionTargetsProvider = Provider<AsyncValue<NutritionTargets>>(
  (ref) => ref
      .watch(profileProvider)
      .whenData(
        (p) => NutritionTargets(
          calories: p.calorieTarget.toDouble(),
          protein: p.proteinTargetG,
          carbs: p.carbsTargetG,
          fat: p.fatTargetG,
          fiber: p.fiberTargetG,
        ),
      ),
);

// ---------------------------------------------------------------------------
// Food lists
// ---------------------------------------------------------------------------

final favoriteFoodsProvider = StreamProvider<List<Food>>(
  (ref) => ref.watch(foodRepositoryProvider).watchFavorites(),
);

final myFoodsProvider = StreamProvider<List<Food>>(
  (ref) => ref.watch(foodRepositoryProvider).watchAll(),
);

final recentFoodsProvider = StreamProvider<List<Food>>(
  (ref) => ref.watch(foodRepositoryProvider).watchRecents(),
);

final recipesProvider = StreamProvider<List<RecipeWithIngredients>>(
  (ref) => ref.watch(recipeRepositoryProvider).watchAll(),
);

final savedMealsProvider = StreamProvider<List<SavedMealWithItems>>(
  (ref) => ref.watch(savedMealRepositoryProvider).watchAll(),
);

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

class NutritionHistory {
  const NutritionHistory({required this.days, required this.entries});
  final List<DaySummary> days;
  final List<FoodLogEntry> entries;

  List<LogLine> get lines => [for (final e in entries) e.line];
}

/// (start, end) inclusive.
final nutritionHistoryProvider =
    StreamProvider.family<NutritionHistory, (String, String)>((ref, range) {
      final (start, end) = range;
      final dates = LocalDates.range(start, end);
      return ref
          .watch(foodLogRepositoryProvider)
          .watchRange(start, end)
          .map(
            (entries) => NutritionHistory(
              days: summarizeDays(dates, [for (final e in entries) e.line]),
              entries: entries,
            ),
          );
    });

final weightRangeProvider =
    StreamProvider.family<List<WeightPoint>, (String, String)>(
      (ref, range) =>
          ref.watch(weightQueryProvider).watchRange(range.$1, range.$2),
    );

// ---------------------------------------------------------------------------
// Hydration (uses the shared WaterRepository)
// ---------------------------------------------------------------------------

final waterDayProvider = StreamProvider.family<List<WaterLog>, String>(
  (ref, date) => ref.watch(waterRepositoryProvider).watchDay(date),
);

/// Last 7 days of water totals ending at [endDate]; refreshes whenever the
/// end day's log changes.
final waterWeekProvider = StreamProvider.family<Map<String, int>, String>((
  ref,
  endDate,
) {
  final repo = ref.watch(waterRepositoryProvider);
  return repo
      .watchDay(endDate)
      .asyncMap(
        (_) => repo.totalsByDay(LocalDates.addDays(endDate, -6), endDate),
      );
});

// ---------------------------------------------------------------------------
// Consent
// ---------------------------------------------------------------------------

final aiPhotoConsentProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(SettingKeys.aiPhotoConsent)
      .map((v) => v ?? false),
);
