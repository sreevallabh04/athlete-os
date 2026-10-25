import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import '../../core/motion/page_transitions.dart';
import 'dev_gallery_screen.dart';

/// `/dev/gallery`: the HUD component gallery (QA screenshots, reference).
final devGalleryRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.devGallery,
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: (context, state) => hudPage(state, const DevGalleryScreen()),
  ),
];
