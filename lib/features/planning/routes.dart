import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/competition_screen.dart';
import 'presentation/planner_screen.dart';
import 'presentation/privacy_data_screen.dart';
import 'presentation/profile_goals_screen.dart';
import 'presentation/reports_screen.dart';
import 'presentation/settings_screen.dart';

/// Full-screen routes owned by the planning feature (pushed above the shell).
final planningRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.competition,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const CompetitionScreen(),
  ),
  GoRoute(
    path: AppPaths.planner,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const PlannerScreen(),
  ),
  GoRoute(
    path: AppPaths.reports,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const ReportsScreen(),
  ),
  GoRoute(
    path: AppPaths.settings,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const SettingsScreen(),
  ),
  GoRoute(
    path: AppPaths.profile,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const ProfileGoalsScreen(),
  ),
  GoRoute(
    path: AppPaths.privacy,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const PrivacyDataScreen(),
  ),
];
