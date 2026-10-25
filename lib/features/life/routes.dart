import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/habits_screen.dart';
import 'presentation/journal_screen.dart';
import 'presentation/life_screen.dart';
import 'presentation/mood_screen.dart';
import 'presentation/notification_settings_screen.dart';

/// Root of the `Life` bottom-navigation branch.
GoRoute lifeTabRoute() => GoRoute(
  path: AppPaths.life,
  builder: (context, state) => const LifeScreen(),
);

/// Full-screen routes owned by the life feature (pushed above the shell).
final lifeRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.habits,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const HabitsScreen(),
  ),
  GoRoute(
    path: AppPaths.mood,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const MoodScreen(),
  ),
  GoRoute(
    path: AppPaths.journal,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const JournalScreen(),
  ),
  GoRoute(
    path: AppPaths.notificationSettings,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const NotificationSettingsScreen(),
  ),
];
