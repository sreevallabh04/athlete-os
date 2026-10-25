import 'package:athlete_os/features/assistant/domain/briefing_builder.dart';
import 'package:athlete_os/features/coach/agent/briefing.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_status.dart';
import 'package:athlete_os/features/coach/presentation/widgets/quick_commands.dart';
import 'package:athlete_os/features/coach/voice/speech_ports.dart';
import 'package:athlete_os/features/coach/voice/voice_controller.dart';
import 'package:athlete_os/features/coach/voice/voice_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fakes.dart';

void main() {
  group('speakableSummary', () {
    test('strips markup, skips tables and long lists', () {
      const text =
          'You have **91 g** of protein left.\n\n'
          '- Dinner: chicken gets you **55 g**\n'
          '- Shake: **25 g**\n'
          '- Walk: 2,000 steps\n'
          '- Fourth bullet is never read\n'
          '| a | b |\n|---|---|';
      final s = speakableSummary(text);
      expect(s, startsWith('You have 91 g of protein left.'));
      expect(s, isNot(contains('**')));
      expect(s, isNot(contains('|')));
      expect(s, isNot(contains('Fourth')));
      expect(s.length, lessThanOrEqualTo(260));
    });

    test('cuts a very long first sentence cleanly', () {
      final s = speakableSummary('word ' * 200);
      expect(s.length, lessThanOrEqualTo(262));
      expect(s.endsWith('…'), isTrue);
    });
  });

  test('pickDefaultVoice prefers a local British voice', () {
    final v = pickDefaultVoice(const [
      TtsVoice('en-us-x-iol-local', 'en-US'),
      TtsVoice('en-gb-x-gba-network', 'en-GB', network: true),
      TtsVoice('en-gb-x-gba-local', 'en-GB'),
      TtsVoice('en-gb-x-rjs-local', 'en_GB'),
    ]);
    expect(v?.name, 'en-gb-x-rjs-local');
    expect(
      pickDefaultVoice(const [TtsVoice('en-us-x-iol-local', 'en-US')])?.locale,
      'en-US',
    );
    expect(pickDefaultVoice(const []), isNull);
  });

  test('voice settings round-trip and clamp', () {
    const s = VoiceSettings(
      autoSpeak: AutoSpeak.always,
      voiceName: 'v',
      rate: 0.6,
      wakeOnOpen: true,
    );
    final back = VoiceSettings.fromJson(s.toJson());
    expect(back.autoSpeak, AutoSpeak.always);
    expect(back.voiceName, 'v');
    expect(back.rate, 0.6);
    expect(back.wakeOnOpen, isTrue);
    expect(VoiceSettings.fromJson({'rate': 9}).rate, 0.9);
    // Defaults: voice on, speak voice turns, never wake on open.
    const d = VoiceSettings();
    expect(d.enabled, isTrue);
    expect(d.autoSpeak, AutoSpeak.voice);
    expect(d.wakeOnOpen, isFalse);
  });

  group('VoiceController', () {
    late FakeRecognizer stt;
    late FakeSynth tts;
    late ProviderContainer c;

    setUp(() {
      stt = FakeRecognizer(partial: 'how much');
      tts = FakeSynth();
      c = ProviderContainer(
        overrides: [
          speechRecognizerProvider.overrideWithValue(stt),
          speechSynthProvider.overrideWithValue(tts),
        ],
      );
      addTearDown(c.dispose);
    });

    test('push-to-talk: partials stream, final is delivered once', () async {
      final heard = <String>[];
      final levels = <double>[];
      final sub = c
          .read(voiceControllerProvider.notifier)
          .levels
          .listen(levels.add);
      addTearDown(sub.cancel);
      final ok = await c
          .read(voiceControllerProvider.notifier)
          .startListening(onFinal: heard.add);
      expect(ok, isTrue);
      expect(c.read(voiceControllerProvider).listening, isTrue);
      expect(c.read(voiceControllerProvider).partial, 'how much');
      stt.finish('how much protein is left');
      stt.finish('how much protein is left');
      expect(heard, ['how much protein is left']);
      expect(c.read(voiceControllerProvider).phase, VoicePhase.idle);
      await Future<void>.delayed(Duration.zero);
      expect(levels, isNotEmpty);
    });

    test('release (stop) delivers the partial transcript', () async {
      final heard = <String>[];
      final v = c.read(voiceControllerProvider.notifier);
      await v.startListening(onFinal: heard.add);
      await v.stopListening();
      expect(heard, ['how much']);
      expect(stt.stopCalls, 1);
    });

    test('denied permission is reported, never retried silently', () async {
      stt
        ..permission = false
        ..issue = RecognizerIssue.permissionDenied;
      final ok = await c
          .read(voiceControllerProvider.notifier)
          .startListening(onFinal: (_) {});
      expect(ok, isFalse);
      expect(
        c.read(voiceControllerProvider).issue,
        RecognizerIssue.permissionDenied,
      );
      expect(stt.listenCalls, 0);
    });

    test('speaks a concise summary with the British default voice', () async {
      await c
          .read(voiceControllerProvider.notifier)
          .speak(
            'All **set**.\n\n| table | row |\n- one\n- two',
            const VoiceSettings(),
          );
      expect(tts.spoken.single, 'All set. one. two.');
      expect(tts.configuredVoice?.name, 'en-gb-x-rjs-local');
      final s = c.read(voiceControllerProvider);
      expect(s.phase, VoicePhase.idle);
      expect(s.wordTick, greaterThan(0));
    });

    test('voice disabled → nothing is spoken', () async {
      await c
          .read(voiceControllerProvider.notifier)
          .speak('Hello.', const VoiceSettings(enabled: false));
      expect(tts.spoken, isEmpty);
    });
  });

  group('briefing', () {
    final now = DateTime(2026, 10, 26, 7, 30);
    const lines = [
      BriefingLine(BriefingKind.steps, '8,000 steps to go (2,000 of 10,000)'),
      BriefingLine(BriefingKind.protein, '170 g protein remaining'),
      BriefingLine(BriefingKind.water, 'Water goal reached', done: true),
      BriefingLine(BriefingKind.calendar, 'Calendar not connected'),
      BriefingLine(BriefingKind.drafts, '2 replies waiting for you'),
    ];

    test('morning briefing is deterministic and honest', () {
      final text = composeBriefing(
        BriefingMode.morning,
        CoachBriefingInputs(now: now, name: 'Sreevallabh', lines: lines),
      );
      expect(text, startsWith('Good morning, Sreevallabh.'));
      expect(text, contains('Monday 26 October'));
      expect(text, contains('**8,000 steps** to go'));
      expect(text, contains('- Calendar not connected'));
      expect(text, contains('- **2** replies waiting'));
      expect(text, contains('- Water goal reached ✓'));
      expect(text, contains('no programme yet'));
      // Same inputs → same text.
      expect(
        composeBriefing(
          BriefingMode.morning,
          CoachBriefingInputs(now: now, name: 'Sreevallabh', lines: lines),
        ),
        text,
      );
    });

    test('evening review counts what closed and what is open', () {
      final text = composeBriefing(
        BriefingMode.evening,
        CoachBriefingInputs(
          now: DateTime(2026, 10, 26, 21),
          name: 'Sreevallabh',
          lines: lines,
        ),
      );
      expect(text, startsWith('Evening review, Sreevallabh'));
      expect(text, contains('✓ Water'));
      expect(text, contains('1 of 4 closed'));
      expect(
        composeBriefing(
          BriefingMode.evening,
          CoachBriefingInputs(now: DateTime(2026, 10, 26, 21)),
        ),
        contains('No data logged today yet'),
      );
    });

    test('polish prompt forbids new facts', () {
      final p = briefingPolishPrompt('You are JARVIS.');
      expect(p, contains('use ONLY the facts'));
      expect(p, contains('keep every number'));
      expect(briefingModeFor(DateTime(2026, 1, 1, 9)), BriefingMode.morning);
      expect(briefingModeFor(DateTime(2026, 1, 1, 19)), BriefingMode.evening);
      expect(briefingModeFor(DateTime(2026, 1, 1, 2)), BriefingMode.evening);
    });
  });

  group('quick commands', () {
    test('time of day and data decide the suggestions', () {
      final morning = quickCommands(
        QuickContext(
          now: DateTime(2026, 10, 26, 8),
          hasNutritionTarget: true,
          hasSessionToday: true,
        ),
      );
      expect(morning.first.label, 'Brief me');
      expect(morning.first.action, QuickAction.brief);
      expect(morning.map((c) => c.label), contains('How much protein left?'));
      expect(morning.map((c) => c.label), contains("What's my session today?"));

      final evening = quickCommands(
        QuickContext(now: DateTime(2026, 10, 26, 21)),
      );
      expect(evening.first.label, 'Review my day');
      // No nutrition target → no protein suggestion.
      expect(
        evening.map((c) => c.label),
        isNot(contains('How much protein left?')),
      );
      final drafts = quickCommands(
        QuickContext(now: DateTime(2026, 10, 26, 13), pendingDrafts: 2),
      );
      expect(
        drafts.map((c) => c.label),
        contains('2 replies awaiting approval'),
      );
      expect(drafts.length, lessThanOrEqualTo(7));
    });

    test('voice shortcuts map to briefings', () {
      expect(matchVoiceCommand('Brief me'), QuickAction.brief);
      expect(matchVoiceCommand('jarvis, brief me.'), QuickAction.brief);
      expect(matchVoiceCommand('Review my day'), QuickAction.review);
      expect(matchVoiceCommand('brief me on protein'), isNull);
    });
  });

  group('link status', () {
    test('honest states from backend + ai-status + last response', () {
      expect(
        deriveCoachLink(backend: AiBackendState.unconfigured).label,
        'Offline',
      );
      final status = {
        'provider_order': ['gemini', 'groq'],
        'providers': [
          {
            'provider': 'gemini',
            'configured': true,
            'circuit': 'open',
            'aliases': [
              {'status': 'ok'},
            ],
          },
          {
            'provider': 'groq',
            'configured': true,
            'circuit': 'closed',
            'aliases': [
              {'status': 'ok'},
            ],
          },
        ],
      };
      final fb = deriveCoachLink(backend: AiBackendState.ready, status: status);
      expect((fb.label, fb.detail), ('Fallback', 'Groq'));
      final live = deriveCoachLink(
        backend: AiBackendState.ready,
        status: status,
        lastProvider: 'gemini',
        lastLatency: const Duration(milliseconds: 2400),
      );
      expect((live.label, live.detail), ('Online', 'Gemini'));
      expect(live.latency, const Duration(milliseconds: 2400));
      final used = deriveCoachLink(
        backend: AiBackendState.ready,
        lastProvider: 'groq',
        fallbackUsed: true,
      );
      expect(used.tone, LinkTone.fallback);
      expect(
        deriveCoachLink(
          backend: AiBackendState.ready,
          statusLoading: true,
        ).tone,
        LinkTone.linking,
      );
    });
  });
}
