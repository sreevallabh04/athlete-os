import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

/// Fixed "now" for every golden-path test: Sunday 2026-10-25, 09:00 local.
final goldenNow = DateTime(2026, 10, 25, 9);
const goldenToday = '2026-10-25';

/// A container with the in-memory [db], a fixed clock and [extra] overrides.
/// Disposed automatically at the end of the test.
ProviderContainer goldenContainer(
  AppDatabase db, {
  List<Override> extra = const [],
  DateTime? now,
}) {
  final c = ProviderContainer(
    overrides: [
      ...testOverrides(db, now: now ?? goldenNow),
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// Hosts [home] inside an existing [container] (so the test can read the
/// same providers the screen uses).
Widget hostIn(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: home),
    );

/// Tall phone-ish surface so long screens lay out without scrolling.
void useTallView(WidgetTester tester, {Size size = const Size(1280, 4200)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps in small fixed steps until [finder] matches. Never uses
/// `pumpAndSettle` (the HUD animates continuously).
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxSteps = 150,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxSteps; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

/// Pumps [count] frames of [step] (lets drift streams emit and short
/// animations finish).
Future<void> pumpFrames(
  WidgetTester tester, {
  int count = 5,
  Duration step = const Duration(milliseconds: 200),
}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(step);
  }
}

/// Reads a stream/future provider's value from a widget test, pumping so
/// drift streams can emit inside the fake-async zone.
Future<T> readAsync<T>(
  WidgetTester tester,
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider, {
  bool Function(T value)? until,
}) async {
  final sub = container.listen(provider, (_, _) {});
  try {
    for (var i = 0; i < 100; i++) {
      final v = sub.read();
      if (v.hasValue &&
          !v.isLoading &&
          (until == null || until(v.value as T))) {
        return v.value as T;
      }
      if (v.hasError) throw v.error!;
      await tester.pump(const Duration(milliseconds: 20));
    }
    final v = sub.read();
    fail('provider never produced the expected value (last: $v)');
  } finally {
    sub.close();
  }
}

/// TESTING.md teardown recipe for widget tests that use Drift streams.
Future<void> driftTeardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

/// Plain-test (non-widget) read of an async provider: keeps a listener so
/// Riverpod 3 does not pause it, then awaits its first value.
Future<T> readFirst<T>(
  ProviderContainer container,
  ProviderListenable<Future<T>> future,
  ProviderListenable<Object?> provider,
) async {
  final sub = container.listen(provider, (_, _) {});
  try {
    return await container.read(future).timeout(const Duration(seconds: 5));
  } finally {
    sub.close();
  }
}
