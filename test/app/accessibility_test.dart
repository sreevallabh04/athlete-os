// Accessibility guidelines on the five tab roots (seeded, real fonts):
// Android tap targets (48 dp), labelled tap targets, text contrast, and
// "every enabled button can be activated by TalkBack".
import 'dart:ui' show Tristate;

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/real_fonts.dart';
import '../helpers/test_app.dart';
import 'route_coverage_test.dart' show seedEverything;

final _now = DateTime(2026, 10, 26, 13, 5);

Future<void> _pumpTab(WidgetTester tester, String path) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  tester.view.padding = const FakeViewPadding(top: 88, bottom: 50);
  tester.view.viewPadding = const FakeViewPadding(top: 88, bottom: 50);
  addTearDown(tester.view.reset);
  final db = newTestDb();
  await tester.runAsync(() => seedEverything(db));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...testOverrides(db, now: _now),
        routerProvider.overrideWith(
          (ref) => buildRouter(initialLocation: path),
        ),
      ],
      child: const AthleteOsApp(),
    ),
  );
  // Let data load and every entrance animation finish.
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  addTearDown(() => tester.runAsync(db.close));
}

/// Labels of enabled, unselected buttons that expose no tap action. A
/// `Semantics(excludeSemantics: true)` wrapper silently drops its child's
/// tap unless it re-exposes `onTap`, which leaves TalkBack users stuck.
List<String> buttonsWithoutTap(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    final f = d.flagsCollection;
    if (f.isButton &&
        f.isEnabled != Tristate.isFalse &&
        f.isSelected != Tristate.isTrue &&
        !d.hasAction(SemanticsAction.tap)) {
      out.add(d.label);
    }
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
  visit(owner.rootSemanticsNode!);
  return out;
}

void main() {
  setUpAll(loadRealFonts);

  for (final path in ['/today', '/train', '/nutrition', '/coach', '/life']) {
    testWidgets('$path meets tap-target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpTab(tester, path);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      expect(buttonsWithoutTap(tester), isEmpty);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    });
  }
}
