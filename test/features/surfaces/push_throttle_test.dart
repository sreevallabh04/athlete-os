import 'dart:convert';

import 'package:athlete_os/features/surfaces/application/widget_sync.dart';
import 'package:athlete_os/features/surfaces/data/surfaces_platform.dart';
import 'package:athlete_os/features/surfaces/domain/push_throttle.dart';
import 'package:athlete_os/features/surfaces/domain/widget_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const interval = Duration(seconds: 15);

  PushThrottle<String> throttle(List<String> out) => PushThrottle<String>(
    interval: interval,
    push: (v) async => out.add(v),
    keyOf: (v) => v,
  );

  testWidgets('first value is pushed immediately, then ≤ 1 per 15 s', (
    tester,
  ) async {
    final out = <String>[];
    final t = throttle(out);

    t.add('a');
    expect(out, ['a']);

    t
      ..add('b')
      ..add('c')
      ..add('d');
    await tester.pump(const Duration(seconds: 14));
    expect(out, ['a'], reason: 'still cooling down');

    await tester.pump(const Duration(seconds: 1));
    expect(out, ['a', 'd'], reason: 'coalesced to the latest value');

    // Another burst inside the next window.
    t.add('e');
    await tester.pump(const Duration(seconds: 5));
    expect(out, ['a', 'd']);
    await tester.pump(const Duration(seconds: 10));
    expect(out, ['a', 'd', 'e']);

    // Quiet period → next value goes out immediately again.
    await tester.pump(const Duration(seconds: 16));
    t.add('f');
    expect(out, ['a', 'd', 'e', 'f']);
    t.dispose();
  });

  testWidgets('unchanged content is not pushed again', (tester) async {
    final out = <String>[];
    final t = throttle(out);

    t.add('a');
    await tester.pump(const Duration(seconds: 20));
    t.add('a');
    expect(out, ['a']);

    t.add('b');
    expect(out, ['a', 'b']);

    // Changed then changed back within the window: nothing to push.
    t
      ..add('c')
      ..add('b');
    await tester.pump(const Duration(seconds: 20));
    expect(out, ['a', 'b']);
    t.dispose();
  });

  testWidgets('flush pushes the pending value without waiting', (tester) async {
    final out = <String>[];
    final t = throttle(out);

    t
      ..add('a')
      ..add('b');
    t.flush();
    expect(out, ['a', 'b']);
    t.flush();
    expect(out, ['a', 'b'], reason: 'nothing pending');
    await tester.pump(const Duration(seconds: 20));
    expect(out, ['a', 'b']);
    t.dispose();
  });

  testWidgets('a failed push is retried on the next value', (tester) async {
    var fail = true;
    final out = <String>[];
    final t = PushThrottle<String>(
      interval: interval,
      push: (v) async {
        if (fail) throw StateError('no host');
        out.add(v);
      },
      keyOf: (v) => v,
    );

    t.add('a');
    await tester.pump();
    fail = false;
    await tester.pump(const Duration(seconds: 20));
    t.add('a');
    expect(out, ['a']);
    t.dispose();
  });

  testWidgets('WidgetSyncService pushes encoded snapshots', (tester) async {
    final platform = FakeSurfacesPlatform();
    final sync = WidgetSyncService(platform);
    final now = DateTime(2026, 10, 26, 9);

    sync.onSnapshot(null);
    expect(platform.widgetUpdates, isEmpty);

    sync.onSnapshot(buildWidgetSnapshot(now: now));
    await tester.pump();
    expect(platform.widgetUpdates, hasLength(1));
    final json = jsonDecode(platform.widgetUpdates.single) as Map;
    expect(json['date'], '2026-10-26');

    // Same content a minute later: no extra update.
    await tester.pump(const Duration(seconds: 20));
    sync.onSnapshot(
      buildWidgetSnapshot(now: now.add(const Duration(minutes: 1))),
    );
    await tester.pump();
    expect(platform.widgetUpdates, hasLength(1));
    expect(widgetPushInterval, interval);
    sync.dispose();
  });
}
