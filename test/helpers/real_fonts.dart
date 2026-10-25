import 'dart:io';

import 'package:flutter/services.dart';

bool _loaded = false;

/// Registers the bundled app fonts (and Material icons) so layout tests
/// measure real glyphs instead of the wide `FlutterTest` font. Without this,
/// overflow checks report false positives. Call inside `tester.runAsync` or
/// `setUpAll`; safe to call repeatedly.
Future<void> loadRealFonts() async {
  if (_loaded) return;
  // Synchronous reads: async file IO never completes inside fake async.
  Future<ByteData> bytes(String path) =>
      Future.value(ByteData.view(File(path).readAsBytesSync().buffer));
  const families = {
    'Inter': ['Regular', 'Medium', 'SemiBold', 'Bold'],
    'InterDisplay': ['SemiBold', 'Bold', 'ExtraBold'],
    'Rajdhani': ['Medium', 'SemiBold', 'Bold'],
    'JetBrainsMono': ['Regular', 'SemiBold'],
  };
  for (final e in families.entries) {
    final loader = FontLoader(e.key);
    for (final w in e.value) {
      loader.addFont(bytes('assets/fonts/${e.key}-$w.ttf'));
    }
    await loader.load();
  }
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(bytes(icons.path))).load();
  }
  _loaded = true;
}
