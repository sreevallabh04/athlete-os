/// Deep links into the app from home-screen surfaces (widget, launcher
/// shortcuts, Quick Settings tile) and from other apps.
///
/// Format: `athleteos://open/<route>[?<param>=<value>]`. The host is always
/// `open`; `athleteos://localhost/...` stays reserved for OAuth redirects
/// (Strava, Supabase) and is never handled here.
///
/// External intents are untrusted input, so links are resolved against a
/// fixed allowlist: unknown routes, path parameters, extra path segments and
/// unknown query parameters are dropped, and every accepted query value is
/// checked against its own allowlist. Pure Dart (unit-tested).
library;

import '../../../app/paths.dart';

const deepLinkScheme = 'athleteos';
const deepLinkHost = 'open';

/// Extra work to do after navigating.
enum DeepLinkAction {
  none,

  /// Open the water quick-add sheet on top of the hydration screen.
  quickAddWater,
}

/// How to navigate: tab roots are switched to (`go`), everything else is
/// pushed on top of the current stack so Back returns to where you were.
enum DeepLinkMode { go, push }

/// A resolved, safe navigation target.
class DeepLinkTarget {
  const DeepLinkTarget(
    this.location, {
    this.mode = DeepLinkMode.push,
    this.action = DeepLinkAction.none,
  });

  /// In-app GoRouter location (path + sanitised query).
  final String location;
  final DeepLinkMode mode;
  final DeepLinkAction action;

  @override
  bool operator ==(Object other) =>
      other is DeepLinkTarget &&
      other.location == location &&
      other.mode == mode &&
      other.action == action;

  @override
  int get hashCode => Object.hash(location, mode, action);

  @override
  String toString() => 'DeepLinkTarget($location, $mode, $action)';
}

/// One allowlisted route: the link path (after `open/`), the in-app path and
/// the query parameters it may carry (name → allowed values).
class _Route {
  const _Route(
    this.appPath, {
    this.mode = DeepLinkMode.push,
    this.params = const {},
    this.action,
  });
  final String appPath;
  final DeepLinkMode mode;
  final Map<String, Set<String>> params;

  /// Picks an action from the sanitised parameters.
  final DeepLinkAction Function(Map<String, String> params)? action;
}

const _flag = {'1'};
const _meals = {'breakfast', 'lunch', 'dinner', 'snack', 'snacks'};

DeepLinkAction _hydrationAction(Map<String, String> p) =>
    p['quickAdd'] == '1' ? DeepLinkAction.quickAddWater : DeepLinkAction.none;

/// The complete allowlist. Keys are link paths without the leading slash.
final Map<String, _Route> _routes = {
  'today': const _Route(AppPaths.today, mode: DeepLinkMode.go),
  'train': const _Route(AppPaths.train, mode: DeepLinkMode.go),
  'nutrition': const _Route(AppPaths.nutrition, mode: DeepLinkMode.go),
  'coach': const _Route(
    AppPaths.coach,
    mode: DeepLinkMode.go,
    params: {'listen': _flag},
  ),
  'life': const _Route(AppPaths.life, mode: DeepLinkMode.go),
  'nutrition/add': const _Route(AppPaths.addFood, params: {'meal': _meals}),
  'hydration': const _Route(
    AppPaths.hydration,
    params: {'quickAdd': _flag},
    action: _hydrationAction,
  ),
  'steps': const _Route(AppPaths.steps),
  'health': const _Route(AppPaths.healthOverview),
  'session': const _Route(AppPaths.program),
  'train/program': const _Route(AppPaths.program),
  'routine': const _Route(AppPaths.routine),
  'assistant': const _Route(AppPaths.assistant),
};

/// Link paths accepted by [resolveDeepLink] (for docs/tests).
Iterable<String> get allowedDeepLinkPaths => _routes.keys;

/// Builds an `athleteos://open/...` link (used by tests and docs; the native
/// side hard-codes the same strings).
Uri deepLinkUri(String path, [Map<String, String>? query]) => Uri(
  scheme: deepLinkScheme,
  host: deepLinkHost,
  path: '/$path',
  queryParameters: (query == null || query.isEmpty) ? null : query,
);

/// Resolves [raw] (a string from a platform intent) to a safe target, or
/// null when it is not an allowlisted `athleteos://open/...` link.
DeepLinkTarget? resolveDeepLink(String? raw) {
  if (raw == null || raw.isEmpty || raw.length > 512) return null;
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    return null;
  }
  if (uri.scheme.toLowerCase() != deepLinkScheme) return null;
  if (uri.host.toLowerCase() != deepLinkHost) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort) return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  if (segments.any((s) => s == '.' || s == '..')) return null;
  final route = _routes[segments.join('/').toLowerCase()];
  if (route == null) return null;

  final kept = <String, String>{};
  final Map<String, List<String>> all;
  try {
    all = uri.queryParametersAll;
  } on FormatException {
    return null;
  }
  for (final entry in route.params.entries) {
    final values = all[entry.key];
    if (values == null || values.length != 1) continue;
    final v = values.single.toLowerCase();
    if (entry.value.contains(v)) {
      kept[entry.key] = v == 'snacks' ? 'snack' : v;
    }
  }

  final action = route.action?.call(kept) ?? DeepLinkAction.none;
  // quickAdd is consumed by the action; it is not a screen parameter.
  final screenParams = Map.of(kept)..remove('quickAdd');
  final location = Uri(
    path: route.appPath,
    queryParameters: screenParams.isEmpty ? null : screenParams,
  ).toString();
  return DeepLinkTarget(location, mode: route.mode, action: action);
}
