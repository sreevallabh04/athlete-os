import 'package:athlete_os/core/haptics/haptics.dart';
import 'package:athlete_os/core/motion/motion.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {bool reduce = false}) => MaterialApp(
  theme: AppTheme.dark(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  late List<String> vibrations;

  setUp(() {
    vibrations = [];
    Haptics.enabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            vibrations.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    Haptics.enabled = true;
    Haptics.debugAllowPatternsInTests = false;
    Haptics.debugOnEvent = null;
  });

  group('Haptics', () {
    testWidgets('semantic calls map to platform feedback', (tester) async {
      Haptics.selection();
      Haptics.light();
      Haptics.medium();
      Haptics.heavy();
      await tester.pump();
      expect(vibrations, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.heavyImpact',
      ]);
    });

    testWidgets('global toggle silences everything', (tester) async {
      Haptics.enabled = false;
      Haptics.light();
      Haptics.success();
      Haptics.goalReached();
      await tester.pump(const Duration(seconds: 1));
      expect(vibrations, isEmpty);
    });

    testWidgets('patterns play their full sequence', (tester) async {
      Haptics.debugAllowPatternsInTests = true;
      final events = <String>[];
      Haptics.debugOnEvent = events.add;
      Haptics.success();
      await tester.pump(const Duration(milliseconds: 200));
      expect(vibrations, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      vibrations.clear();
      Haptics.goalReached();
      await tester.pump(const Duration(milliseconds: 600));
      expect(vibrations, hasLength(5));
      expect(events, ['success', 'goalReached']);
    });
  });

  group('PressableScale', () {
    testWidgets('taps fire the callback and a haptic', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          PressableScale(
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 50, child: Text('Press')),
          ),
        ),
      );
      await tester.tap(find.text('Press'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(taps, 1);
      expect(vibrations, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets('scales down while held and springs back', (tester) async {
      await tester.pumpWidget(
        _app(
          PressableScale(
            onTap: () {},
            child: const SizedBox(width: 100, height: 50, child: Text('Hold')),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold')),
      );
      // Tap-down fires after kPressTimeout; the spring then needs frames.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      final held = tester
          .widget<Transform>(
            find
                .ancestor(
                  of: find.text('Hold'),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .storage[0]; // x scale
      expect(held, lessThan(0.99));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final released = tester
          .widget<Transform>(
            find
                .ancestor(
                  of: find.text('Hold'),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .storage[0]; // x scale
      expect(released, closeTo(1, 0.01));
    });

    testWidgets('inert without callbacks', (tester) async {
      await tester.pumpWidget(
        _app(const PressableScale(child: Text('Static'))),
      );
      await tester.tap(find.text('Static'), warnIfMissed: false);
      await tester.pump();
      expect(vibrations, isEmpty);
    });
  });

  group('AnimatedTicker', () {
    testWidgets('final text is findable while rolling and after', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const AnimatedTicker('8,432')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('8,432'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('8,432'), findsOneWidget);

      await tester.pumpWidget(_app(const AnimatedTicker('9,001')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('9,001'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('9,001'), findsOneWidget);
    });

    testWidgets('value factory groups thousands and decimals', (tester) async {
      await tester.pumpWidget(
        _app(AnimatedTicker.value(12345.678, fractionDigits: 1, suffix: ' kg')),
      );
      expect(find.text('12,345.7 kg'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('reduced motion renders immediately', (tester) async {
      await tester.pumpWidget(_app(const AnimatedTicker('42'), reduce: true));
      expect(find.byType(ShaderMask), findsNothing);
      expect(find.text('42'), findsOneWidget);
    });
  });

  group('Entrance & stagger', () {
    testWidgets('children appear and keep state after the animation', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          StaggeredList(
            children: [for (var i = 0; i < 3; i++) Text('Item $i')],
          ),
        ),
      );
      expect(find.text('Item 2'), findsOneWidget);
      final before = tester.element(find.text('Item 0'));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.element(find.text('Item 0')), same(before));
    });

    test('staggered caps the cascade', () {
      final items = staggered([for (var i = 0; i < 20; i++) Text('$i')]);
      final last = items.last as Entrance;
      expect(last.delay, AppMotion.staggerStep * AppMotion.staggerCap);
    });
  });

  test('SpringCurve starts at 0 and ends at 1', () {
    final c = SpringCurve(AppMotion.gentle);
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    expect(c.transform(0.5), greaterThan(0.5));
  });

  testWidgets('HUD page transition pushes and pops', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        navigatorKey: nav,
        home: const Text('Home'),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Next')),
      ),
    );
    await tester.pump();
    expect(find.byType(HudZoomThrough), findsWidgets);
    await tester.pump(AppMotion.page);
    expect(find.text('Next'), findsOneWidget);
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Next'), findsNothing);
  });
}
