import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/activity_detail_screen.dart';
import 'presentation/running_screen.dart';
import 'presentation/strength_screen.dart';
import 'presentation/train_screen.dart';
import 'presentation/workout_detail_screen.dart';

/// Root of the `Train` bottom-navigation branch.
GoRoute trainTabRoute() => GoRoute(
  path: AppPaths.train,
  builder: (context, state) => const TrainScreen(),
);

/// Full-screen routes owned by the train feature (pushed above the shell).
final trainRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.strength,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const StrengthScreen(),
  ),
  GoRoute(
    path: AppPaths.running,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const RunningScreen(),
  ),
  GoRoute(
    path: AppPaths.activityDetail,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) =>
        ActivityDetailScreen(id: state.pathParameters['id']!),
  ),
  GoRoute(
    path: AppPaths.workoutDetail,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) =>
        WorkoutDetailScreen(id: state.pathParameters['id']!),
  ),
];
