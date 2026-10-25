import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/coach/agent/briefing.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/agent/tool_router.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/presentation/coach_screen.dart';
import 'package:athlete_os/features/coach/presentation/widgets/composer.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:athlete_os/features/coach/voice/speech_ports.dart';
import 'package:athlete_os/features/coach/voice/voice_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';
import 'voice_fakes.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = newTestDb();
    addTearDown(db.close);
  });

  ProviderContainer container(AiBackendClient backend) {
    final c = ProviderContainer(
      overrides: [
        ...testOverrides(db, now: testNow),
        aiBackendClientProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'a tool outside the routed subset still runs and widens the turn',
    () async {
      final backend = FakeAiBackend([
        // "protein" routes nutrition tools; the model asks for competitions.
        (r) => FakeAiBackend.toolCall(r, 'x1', 'get_competition_countdown'),
        (r) => FakeAiBackend.text(r, 'Done.'),
      ]);
      final c = container(backend);
      await c.read(coachControllerProvider.notifier).send('protein please');
      expect(backend.requests, hasLength(2));
      final first = backend.requests.first.tools.map((t) => t['name']).toSet();
      expect(first, isNot(contains('get_competition_countdown')));
      expect(first.length, lessThanOrEqualTo(maxRoutedTools));
      // Widened: the follow-up call carries every tool.
      expect(backend.requests[1].tools.length, coachTools.length);
      final s = c.read(coachControllerProvider);
      expect(
        s.entries.whereType<ToolChipEntry>().single.status,
        ToolChipStatus.ok,
      );
      expect(s.lastProvider, 'anthropic');
      expect(s.lastRequest, isNotNull);
      expect(s.replySerial, 1);
    },
  );

  test('fast retry re-sends on Groq with a new request id', () async {
    var calls = 0;
    final backend = FakeAiBackend([
      (r) {
        calls++;
        throw const AiBackendException('timeout', 'slow');
      },
      (r) => FakeAiBackend.text(r, 'Fast answer.'),
    ]);
    final c = container(backend);
    final ctl = c.read(coachControllerProvider.notifier);
    await ctl.send('How many steps left?');
    expect(c.read(coachControllerProvider).error?.code, 'timeout');
    await ctl.retry(fast: true);
    expect(calls, 1);
    expect(backend.requests, hasLength(2));
    expect(
      backend.requests[1].preferences.toWire()['primary_provider'],
      'groq',
    );
    expect(backend.requests[1].requestId, isNot(backend.requests[0].requestId));
    expect(
      c
          .read(coachControllerProvider)
          .entries
          .whereType<AssistantTextEntry>()
          .last
          .text,
      'Fast answer.',
    );
  });

  test(
    'briefing works offline, is local-only and never sent to a model',
    () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.text(r, 'Model answer.'),
      ]);
      final c = container(const UnconfiguredAiBackend());
      await c
          .read(coachControllerProvider.notifier)
          .brief(BriefingMode.morning);
      final s = c.read(coachControllerProvider);
      expect(s.entries.first, isA<UserTextEntry>());
      final b = s.entries.whereType<BriefingEntry>().single;
      expect(b.text, startsWith('Good morning'));
      expect(b.polished, isFalse);
      expect(s.busy, isFalse);
      expect(s.replySerial, 1);
      final rows = await db.select(db.aiMessages).get();
      expect(rows.map((r) => r.role).toSet(), {localRole});
      expect(toWireMessages(rows), isEmpty);
      expect(backend.requests, isEmpty);
    },
  );

  testWidgets('push-to-talk: first tap explains, then voice sends the turn', (
    tester,
  ) async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.text(r, 'You have **91 g** left.'),
    ]);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final stt = FakeRecognizer(permission: false, partial: 'how much');
    final tts = FakeSynth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: testNow),
          aiBackendClientProvider.overrideWithValue(backend),
          speechRecognizerProvider.overrideWithValue(stt),
          speechSynthProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: CoachScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // First tap: explanation sheet, nothing requested yet.
    await tester.tap(find.bySemanticsLabel('Talk to JARVIS'));
    for (var i = 0; i < 60 && find.text('Continue').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Talk to JARVIS'), findsOneWidget);
    expect(stt.initCalls, 0);
    await tester.tap(find.text('Continue'));
    for (var i = 0; i < 60 && stt.listenCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 600));
    expect(stt.initCalls, 1);
    expect(stt.listenCalls, 1);
    expect(find.text('how much'), findsWidgets);

    stt.finish('how much protein is left');
    for (var i = 0; i < 60 && tts.spoken.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(backend.requests, hasLength(1));
    expect(find.text('how much protein is left'), findsOneWidget);
    // Voice turn → the answer is spoken (default "When I speak").
    await tester.pump(const Duration(milliseconds: 100));
    expect(tts.spoken.single, 'You have 91 g left.');
    expect(c(tester).read(voiceSettingsProvider).value?.micExplained, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('send button reflects backend readiness', (tester) async {
    await tester.pumpWidget(
      testHarness(const CoachScreen(), db: db, now: testNow),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<HudIconAction>(find.byKey(const Key('coach_send'))).onTap,
      isNull,
    );
    expect(find.textContaining('OFFLINE'), findsOneWidget);
    expect(find.byType(JarvisOrb), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}

ProviderContainer c(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CoachScreen)));
