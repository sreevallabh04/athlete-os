import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/calendar_screen.dart';
import 'presentation/integrations_screen.dart';

/// Full-screen routes owned by the integrations feature (pushed above the shell).
final integrationsRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.integrations,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const IntegrationsScreen(),
  ),
  GoRoute(
    path: AppPaths.calendar,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const CalendarScreen(),
  ),
];
