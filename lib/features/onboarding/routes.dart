import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/onboarding_screen.dart';
import 'presentation/program_screen.dart';
import 'presentation/routine_screen.dart';

/// Full-screen routes owned by the onboarding/persona feature.
final onboardingRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.onboarding,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const OnboardingScreen(),
  ),
  GoRoute(
    path: AppPaths.program,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const ProgramScreen(),
  ),
  GoRoute(
    path: AppPaths.routine,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const RoutineScreen(),
  ),
];
