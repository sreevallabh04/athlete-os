import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/ai_history_screen.dart';
import 'presentation/ai_memory_screen.dart';
import 'presentation/ai_provider_settings_screen.dart';
import 'presentation/coach_screen.dart';

/// Root of the `Coach` bottom-navigation branch.
GoRoute coachTabRoute() => GoRoute(
  path: AppPaths.coach,
  builder: (context, state) => const CoachScreen(),
);

/// Full-screen routes owned by the coach feature (pushed above the shell).
final coachRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.aiSettings,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AiProviderSettingsScreen(),
  ),
  GoRoute(
    path: AppPaths.aiMemory,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AiMemoryScreen(),
  ),
  GoRoute(
    path: AppPaths.aiHistory,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AiHistoryScreen(),
  ),
];
