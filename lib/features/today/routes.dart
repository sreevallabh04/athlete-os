import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/today_screen.dart';

/// Root of the `Today` bottom-navigation branch.
GoRoute todayTabRoute() => GoRoute(
  path: AppPaths.today,
  builder: (context, state) => const TodayScreen(),
);

/// Full-screen routes owned by the today feature (pushed above the shell).
final todayRoutes = <RouteBase>[];
