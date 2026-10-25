import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/assistant/routes.dart';
import '../features/coach/routes.dart';
import '../features/devgallery/routes.dart';
import '../features/health/routes.dart';
import '../features/integrations/routes.dart';
import '../features/life/routes.dart';
import '../features/nutrition/routes.dart';
import '../features/onboarding/application/persona_providers.dart';
import '../features/onboarding/routes.dart';
import '../features/planning/routes.dart';
import '../features/today/routes.dart';
import '../features/train/routes.dart';
import 'paths.dart';
import 'shell.dart';

GoRouter buildRouter({String initialLocation = AppPaths.today}) => GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: initialLocation,
  redirect: onboardingRedirect,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(routes: [todayTabRoute()]),
        StatefulShellBranch(routes: [trainTabRoute()]),
        StatefulShellBranch(routes: [nutritionTabRoute()]),
        StatefulShellBranch(routes: [coachTabRoute()]),
        StatefulShellBranch(routes: [lifeTabRoute()]),
      ],
    ),
    ...todayRoutes,
    ...trainRoutes,
    ...nutritionRoutes,
    ...coachRoutes,
    ...lifeRoutes,
    ...healthRoutes,
    ...integrationsRoutes,
    ...planningRoutes,
    ...assistantRoutes,
    ...onboardingRoutes,
    ...devGalleryRoutes,
  ],
);

final routerProvider = Provider<GoRouter>((ref) {
  final router = buildRouter();
  // The onboarding gate may finish loading after the first frame (start-up
  // hooks are time-boxed). Re-run the redirect when it changes so a first
  // launch still lands on /onboarding.
  ref.listen<bool?>(onboardingGateProvider, (prev, next) {
    if (prev != next) router.refresh();
  });
  return router;
});
