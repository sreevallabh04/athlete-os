import 'package:go_router/go_router.dart';

import '../../app/paths.dart';
import 'presentation/assistant_audit_screen.dart';
import 'presentation/assistant_screen.dart';
import 'presentation/assistant_settings_screen.dart';
import 'presentation/capabilities_screen.dart';

/// Full-screen routes owned by the assistant feature.
final assistantRoutes = <RouteBase>[
  GoRoute(
    path: AppPaths.assistant,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AssistantScreen(),
  ),
  GoRoute(
    path: AppPaths.assistantSettings,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AssistantSettingsScreen(),
  ),
  GoRoute(
    path: AppPaths.assistantAudit,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const AssistantAuditScreen(),
  ),
  GoRoute(
    path: AppPaths.capabilities,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, state) => const CapabilitiesScreen(),
  ),
];
