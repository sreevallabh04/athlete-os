import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../domain/deep_links.dart';

/// Navigates for an external `athleteos://open/...` link.
///
/// Only allowlisted targets (see [resolveDeepLink]) are ever navigated to;
/// anything else is ignored and reported as `false`.
class DeepLinkRouter {
  DeepLinkRouter({required this.router, this.onAction});

  /// Resolved lazily so the router can be rebuilt (tests, hot restart).
  final GoRouter Function() router;

  /// Runs a target's follow-up action after navigation (e.g. the water
  /// quick-add sheet). Called on the next frame by the caller's choice.
  final void Function(DeepLinkAction action)? onAction;

  bool open(String? raw) {
    final target = resolveDeepLink(raw);
    if (target == null) {
      debugPrint('deep link ignored (not allowlisted)');
      return false;
    }
    final r = router();
    switch (target.mode) {
      case DeepLinkMode.go:
        r.go(target.location);
      case DeepLinkMode.push:
        // Already showing it (e.g. widget tapped twice): don't stack copies.
        if (_currentPath(r) != Uri.parse(target.location).path) {
          r.push(target.location);
        }
    }
    if (target.action != DeepLinkAction.none) onAction?.call(target.action);
    return true;
  }

  /// Path of the top-most route (including pushed ones), or null before the
  /// router has its first configuration.
  static String? _currentPath(GoRouter r) {
    try {
      return r.state.uri.path;
    } catch (_) {
      return null;
    }
  }
}
