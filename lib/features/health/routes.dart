import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/health_overview_screen.dart';
import 'presentation/health_status_screen.dart';
import 'presentation/steps_screen.dart';

/// Full-screen routes owned by the health feature (pushed above the shell).
final healthRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.steps,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const StepsScreen(),
  ),
  GoRoute(
    path: AppPaths.healthOverview,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const HealthOverviewScreen(),
  ),
  GoRoute(
    path: AppPaths.healthStatus,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const HealthStatusScreen(),
  ),
];
