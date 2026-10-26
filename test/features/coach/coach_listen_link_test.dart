// `/coach?listen=1` (the "Ask JARVIS" launcher shortcut) starts listening on
// arrival through the same explainer/permission flow as a mic tap.
import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/voice/speech_ports.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';
import 'voice_fakes.dart';

/// Pumps the real app at [location], runs [check], then tears down.
Future<void> _withCoach(
  WidgetTester tester,
  String location,
  List<Override> overrides,
  void Function() check,
) async {
  final db = newTestDb();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...testOverrides(db, now: testNow),
        routerProvider.overrideWith(
          (ref) => buildRouter(initialLocation: location),
        ),
        speechSynthProvider.overrideWithValue(FakeSynth()),
        ...overrides,
      ],
      child: const AthleteOsApp(),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  check();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(db.close);
}

void main() {
  testWidgets('listen=1 starts listening when the mic is already allowed', (
    tester,
  ) async {
    final stt = FakeRecognizer();
    await _withCoach(tester, '/coach?listen=1', [
      aiBackendClientProvider.overrideWithValue(FakeAiBackend([])),
      speechRecognizerProvider.overrideWithValue(stt),
    ], () => expect(stt.listenCalls, 1));
  });

  testWidgets('listen=1 explains the mic first and never grabs it unasked', (
    tester,
  ) async {
    final stt = FakeRecognizer(permission: false);
    await _withCoach(
      tester,
      '/coach?listen=1',
      [
        aiBackendClientProvider.overrideWithValue(FakeAiBackend([])),
        speechRecognizerProvider.overrideWithValue(stt),
      ],
      () {
        expect(find.text('Talk to JARVIS'), findsWidgets);
        expect(stt.listenCalls, 0);
      },
    );
  });

  testWidgets('without listen=1 the coach stays quiet', (tester) async {
    final stt = FakeRecognizer();
    await _withCoach(
      tester,
      '/coach',
      [
        aiBackendClientProvider.overrideWithValue(FakeAiBackend([])),
        speechRecognizerProvider.overrideWithValue(stt),
      ],
      () {
        expect(stt.listenCalls, 0);
        expect(find.text('Talk to JARVIS'), findsNothing);
      },
    );
  });

  testWidgets('listen=1 with the AI core offline explains instead', (
    tester,
  ) async {
    final stt = FakeRecognizer();
    await _withCoach(
      tester,
      '/coach?listen=1',
      [speechRecognizerProvider.overrideWithValue(stt)],
      () {
        expect(stt.listenCalls, 0);
        expect(find.textContaining('voice is unavailable'), findsOneWidget);
      },
    );
  });
}
