// Navigation integrity (static): every in-app location written in lib/ —
// `context.push('/...')`, `'${AppPaths.x}?k=v'`, `Uri(path: AppPaths.x,
// queryParameters: {...})`, launcher shortcuts and the deep-link allowlist —
// must resolve to a registered GoRouter route, and every query parameter it
// carries must be read by that route (or its screen). Prevents dead links
// and silently ignored parameters.
import 'dart:io';

import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/features/surfaces/domain/deep_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// `name → '/path'` from lib/app/paths.dart.
Map<String, String> _appPaths() {
  final src = File('lib/app/paths.dart').readAsStringSync();
  return {
    for (final m in RegExp(r"static const (\w+) = '([^']+)';").allMatches(src))
      m.group(1)!: m.group(2)!,
  };
}

Iterable<File> _dartFiles(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

String _rel(File f) => f.path.replaceAll(r'\', '/');

/// A location found in source, with where it came from.
class _Link {
  _Link(this.location, this.where);
  final String location;
  final String where;
  @override
  String toString() => '$location  ($where)';
}

/// Query keys each route path reads: scanned from the `GoRoute` block in
/// `features/*/routes.dart` and from the screen class it builds.
Map<String, Set<String>> _supportedQueryKeys(Map<String, String> paths) {
  final classFiles = <String, String>{};
  for (final f in _dartFiles('lib')) {
    final src = f.readAsStringSync();
    for (final m in RegExp(r'^class (\w+)', multiLine: true).allMatches(src)) {
      classFiles[m.group(1)!] = src;
    }
  }
  final keyRe = RegExp(r"queryParameters\['(\w+)'\]");
  final out = <String, Set<String>>{};
  for (final f in _dartFiles('lib/features')) {
    if (!f.path.endsWith('routes.dart')) continue;
    final src = f.readAsStringSync();
    final blocks = src.split('GoRoute(').skip(1);
    for (final block in blocks) {
      final p = RegExp(r'path: AppPaths\.(\w+)').firstMatch(block);
      if (p == null) continue;
      final path = paths[p.group(1)!]!;
      final keys = out.putIfAbsent(path, () => {});
      keys.addAll(keyRe.allMatches(block).map((m) => m.group(1)!));
      for (final c in RegExp(r'(\w+Screen)\(').allMatches(block)) {
        final screen = classFiles[c.group(1)!];
        if (screen != null) {
          keys.addAll(keyRe.allMatches(screen).map((m) => m.group(1)!));
        }
      }
    }
  }
  return out;
}

List<_Link> _linksInSource(Map<String, String> paths) {
  final links = <_Link>[];
  String expand(String literal) => literal
      .replaceAllMapped(
        RegExp(r'\$\{AppPaths\.(\w+)\}'),
        (m) => paths[m.group(1)!] ?? '/__unknown_AppPaths.${m.group(1)}',
      )
      // Any other interpolation stands for a dynamic segment or value.
      .replaceAll(RegExp(r'\$\{[^}]*\}'), 'x')
      .replaceAll(RegExp(r'\$\w+'), 'x');

  final callRe = RegExp(
    r'''\.(?:push|go|replace|pushReplacement)(?:<[^>(]*>)?\(\s*'(/[^']*)'|\.(?:push|go|replace|pushReplacement)(?:<[^>(]*>)?\(\s*"(/[^"]*)"''',
  );
  final appPathLiteralRe = RegExp(r"""'(\$\{AppPaths\.\w+\}[^']*)'""");
  final uriRe = RegExp(
    r'Uri\(\s*path:\s*AppPaths\.(\w+),\s*queryParameters:\s*\{([^}]*)\}',
  );
  for (final f in _dartFiles('lib')) {
    if (f.path.replaceAll(r'\', '/').endsWith('lib/app/paths.dart')) continue;
    final src = f.readAsStringSync();
    String where(int offset) {
      final line = '\n'.allMatches(src.substring(0, offset)).length + 1;
      return '${_rel(f)}:$line';
    }

    for (final m in callRe.allMatches(src)) {
      links.add(_Link(expand(m.group(1) ?? m.group(2)!), where(m.start)));
    }
    for (final m in appPathLiteralRe.allMatches(src)) {
      links.add(_Link(expand(m.group(1)!), where(m.start)));
    }
    for (final m in uriRe.allMatches(src)) {
      final keys = RegExp(r"'(\w+)'\s*:")
          .allMatches(m.group(2)!)
          .map((k) => '${k.group(1)}=x')
          .join('&');
      final path = paths[m.group(1)!]!;
      links.add(_Link(keys.isEmpty ? path : '$path?$keys', where(m.start)));
    }
  }
  return links;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final paths = _appPaths();
  late GoRouter router;
  setUp(() => router = buildRouter());
  tearDown(() => router.dispose());

  bool routes(String location) {
    final match = router.configuration.findMatch(Uri.parse(location));
    return match.isNotEmpty && !match.isError;
  }

  void expectResolves(String location, String where) {
    expect(
      routes(location),
      isTrue,
      reason: '$location from $where is a dead link',
    );
  }

  test('every AppPaths constant is a registered route', () {
    for (final MapEntry(:key, :value) in paths.entries) {
      final concrete = value.replaceAll(RegExp(r':\w+'), 'x');
      expectResolves(concrete, 'AppPaths.$key');
    }
  });

  test('every literal in-app location in lib/ resolves, with known params', () {
    final links = _linksInSource(paths);
    // The scan must actually find the app's links (guards the regexes).
    expect(links.length, greaterThan(15), reason: links.join('\n'));
    final supported = _supportedQueryKeys(paths);
    for (final link in links) {
      final uri = Uri.parse(link.location);
      expectResolves(uri.path, link.where);
      final pattern = router.configuration.findMatch(uri).fullPath;
      for (final key in uri.queryParameters.keys) {
        expect(
          supported[pattern] ?? const <String>{},
          contains(key),
          reason:
              '${link.location} (${link.where}): "$key" is not read by '
              'the $pattern route',
        );
      }
    }
  });

  test('launcher shortcuts and deep links land on real routes', () {
    final xml = File('android/app/src/main/res/xml/shortcuts.xml')
        .readAsStringSync();
    final shortcutLinks = RegExp(r'android:data="([^"]+)"')
        .allMatches(xml)
        .map((m) => m.group(1)!)
        .toList();
    expect(shortcutLinks, isNotEmpty);
    final supported = _supportedQueryKeys(paths);
    final all = [
      ...shortcutLinks,
      for (final p in allowedDeepLinkPaths) 'athleteos://open/$p',
    ];
    for (final raw in all) {
      final target = resolveDeepLink(raw);
      expect(target, isNotNull, reason: '$raw is not allowlisted');
      final uri = Uri.parse(target!.location);
      expectResolves(uri.path, raw);
      final pattern = router.configuration.findMatch(uri).fullPath;
      for (final key in uri.queryParameters.keys) {
        expect(
          supported[pattern] ?? const <String>{},
          contains(key),
          reason: '$raw: "$key" is not read by the $pattern route',
        );
      }
    }
  });
}
