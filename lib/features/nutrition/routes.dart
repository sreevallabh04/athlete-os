import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/add_food_screen.dart';
import 'presentation/hydration_screen.dart';
import 'presentation/nutrition_history_screen.dart';
import 'presentation/nutrition_screen.dart';

/// Root of the `Nutrition` bottom-navigation branch.
GoRoute nutritionTabRoute() => GoRoute(
  path: AppPaths.nutrition,
  builder: (context, state) => const NutritionScreen(),
);

/// Full-screen routes owned by the nutrition feature (pushed above the shell).
final nutritionRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.addFood,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => AddFoodScreen(
      initialMeal: state.uri.queryParameters['meal'],
      initialDate: state.uri.queryParameters['date'],
    ),
  ),
  GoRoute(
    path: AppPaths.nutritionHistory,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const NutritionHistoryScreen(),
  ),
  GoRoute(
    path: AppPaths.hydration,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const HydrationScreen(),
  ),
];
