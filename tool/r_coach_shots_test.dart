// Visual QA for the JARVIS Coach + Messaging Assistant redesign.
//
//   flutter test tool/r_coach_shots_test.dart            # all shots
//   flutter test tool/r_coach_shots_test.dart --plain-name conversation
//
// Writes build/shots/r-coach/*.png (1080×2400 @ DPR 2.75). Uses scripted
// AI backends and fake voice engines; nothing touches the network.
import 'dart:async';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/application/reply_drafter.dart';
import 'package:athlete_os/features/assistant/data/assistant_platform.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/coach/data/ai_status.dart';
import 'package:athlete_os/features/coach/data/coach_repository.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:athlete_os/features/coach/agent/briefing.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/presentation/coach_screen.dart';
import 'package:athlete_os/features/coach/presentation/coach_telemetry.dart';
import 'package:athlete_os/features/coach/voice/speech_ports.dart';
import 'package:athlete_os/features/coach/voice/voice_controller.dart';
import 'package:athlete_os/features/coach/voice/voice_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../test/features/assistant/assistant_test_utils.dart'
    show FakeDrafter, enableApp, ev, sms, whatsapp;
import '../test/features/coach/coach_test_utils.dart';
import '../test/features/coach/voice_fakes.dart';
import 'screenshots_test.dart';

const _dir = 'r-coach';
final _morning = DateTime(2026, 10, 26, 8, 10);
final _evening = DateTime(2026, 10, 26, 21, 5);

/// Scripted backend with a healthy ai-status.
class ShotBackend extends FakeAiBackend {
  ShotBackend(super.responders);

  @override
  Future<Map<String, Object?>> status() async => {
    'provider_order': ['gemini', 'groq'],
    'providers': [
      {
        'provider': 'gemini',
        'configured': true,
        'default_model': 'gemini-3.6-flash',
        'circuit': 'closed',
        'aliases': [
          {'alias': 'primary', 'status': 'ok'},
          {'alias': 'secondary', 'status': 'ok'},
        ],
      },
      {
        'provider': 'groq',
        'configured': true,
        'default_model': 'openai/gpt-oss-120b',
        'circuit': 'closed',
        'aliases': [
          {'alias': 'primary', 'status': 'ok'},
        ],
      },
      {'provider': 'anthropic', 'configured': false, 'aliases': []},
      {'provider': 'openai', 'configured': false, 'aliases': []},
    ],
    'usage': {
      'month_start': '2026-10-01',
      'requests': 214,
      'input_tokens': 612400,
      'output_tokens': 48210,
      'cost_usd': 0.82,
      'monthly_budget_usd': 10,
      'percent': 8.2,
      'alerts': [],
    },
  };

  @override
  Future<Map<String, Object?>> testProviders({String? provider}) async => {
    'results': [
      if (provider == null || provider == 'gemini') ...[
        {
          'provider': 'gemini',
          'alias': 'primary',
          'ok': true,
          'latency_ms': 1840,
        },
        {
          'provider': 'gemini',
          'alias': 'secondary',
          'ok': true,
          'latency_ms': 2310,
        },
      ],
      if (provider == null || provider == 'groq')
        {'provider': 'groq', 'alias': 'primary', 'ok': true, 'latency_ms': 412},
    ],
  };
}

AiChatResponse _text(AiChatRequest r, String text) => AiChatResponse(
  requestId: r.requestId,
  content: [
    {'type': 'text', 'text': text},
  ],
  stopReason: 'end_turn',
  provider: 'gemini',
  model: 'gemini-3.6-flash',
);

AiChatResponse _tools(
  AiChatRequest r,
  List<(String, String, Map<String, Object?>)> calls,
) => AiChatResponse(
  requestId: r.requestId,
  content: [
    for (final (id, name, args) in calls)
      {'type': 'tool_call', 'id': id, 'name': name, 'arguments': args},
  ],
  stopReason: 'tool_use',
  provider: 'gemini',
  model: 'gemini-3.6-flash',
);

ProviderContainer _container(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(CoachScreen)));

/// Realistic day: profile name, food, water and steps for [date].
Future<void> seedDay(ProviderContainer c, String date) async {
  final db = c.read(databaseProvider);
  await c
      .read(profileRepositoryProvider)
      .update(
        const UserProfilesCompanion(
          displayName: Value('Sreevallabh'),
          proteinTargetG: Value(170),
          stepGoal: Value(10000),
          waterGoalMl: Value(3500),
        ),
      );
  await SettingsRepository(db).set(SettingKeys.aiHealthConsent, true);
  var n = 0;
  Future<void> food(String name, String meal, double kcal, double p) => db
      .into(db.foodLogEntries)
      .insert(
        FoodLogEntriesCompanion.insert(
          id: 'shot-f${n++}',
          name: name,
          mealType: meal,
          calories: kcal,
          proteinG: Value(p),
          source: 'manual',
          verification: 'user_entered',
          loggedAt: DateTime.now().toUtc(),
          localDate: date,
          tzName: 'Asia/Kolkata',
        ),
      );
  await food('Overnight oats with whey', 'breakfast', 520, 38);
  await food('Paneer bhurji, 2 rotis', 'lunch', 690, 41);
  await db
      .into(db.waterLogs)
      .insert(
        WaterLogsCompanion.insert(
          id: 'shot-w1',
          amountMl: 1750,
          loggedAt: DateTime.now().toUtc(),
          localDate: date,
        ),
      );
  await db
      .into(db.dailyHealthSummaries)
      .insert(
        DailyHealthSummariesCompanion.insert(
          localDate: date,
          type: 'steps',
          value: 6240,
          unit: 'count',
          origin: 'health_connect',
          computedAt: Value(DateTime.now()),
        ),
      );
}

Future<void> _settleAsync(WidgetTester t, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Runs [f] in the test's fake-async zone and pumps until it completes.
/// (Awaiting DB work inside `runAsync` deadlocks with fake-zone queries.)
Future<void> _run(
  WidgetTester t,
  Future<void> Function() f, {
  int max = 200,
}) async {
  var done = false;
  Object? error;
  unawaited(
    f().then(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  for (var i = 0; i < max && !done; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  if (error != null) throw error!;
}

List<Override> _voiceFakes({FakeRecognizer? stt, FakeSynth? tts}) => [
  speechRecognizerProvider.overrideWithValue(stt ?? FakeRecognizer()),
  speechSynthProvider.overrideWithValue(tts ?? FakeSynth()),
];

void main() {
  setUpAll(loadShotFonts);

  testWidgets('offline', (t) async {
    await shotRoute(t, '/coach', '$_dir/coach_offline', now: _evening);
  });

  testWidgets('hero online morning', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_hero',
      now: _morning,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        await _run(t, () => seedDay(c, '2026-10-26'));
        c.invalidate(coachTelemetryProvider);
      },
    );
  });

  testWidgets('hero light', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_hero_light',
      now: _evening,
      light: true,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        await _run(t, () => seedDay(c, '2026-10-26'));
        c.invalidate(coachTelemetryProvider);
      },
    );
  });

  Future<void> conversation(
    WidgetTester t,
    String name, {
    bool light = false,
  }) => shotRoute(
    t,
    '/coach',
    name,
    now: _evening,
    light: light,
    overrides: [
      aiBackendClientProvider.overrideWithValue(
        ShotBackend([
          (r) => _tools(r, [
            ('c1', 'get_nutrition_summary', {'date': '2026-10-26'}),
            ('c2', 'get_profile_and_goals', {}),
          ]),
          (r) => _text(
            r,
            'You have **91 g of protein** left today, Sreevallabh — you '
            'are at 79 g of 170 g.\n\n'
            '- Dinner: 250 g grilled chicken or paneer tikka gets you '
            '**~55 g**\n'
            '- A whey shake before bed covers the last **~25 g**\n'
            '- Calories stay comfortably inside your 2,450 kcal target',
          ),
          (r) => _tools(r, [
            ('c3', 'log_water', {'amount_ml': 500}),
          ]),
          (r) => _text(r, 'Logged.'),
        ]),
      ),
      ..._voiceFakes(),
    ],
    prepare: (t) async {
      final c = _container(t);
      await _run(t, () => seedDay(c, '2026-10-26'));
      final ctl = c.read(coachControllerProvider.notifier);
      await _run(t, () => ctl.send('How much protein do I have left today?'));
      await _settleAsync(t, 50);
      await _run(t, () => ctl.send('I just drank 500 ml of water'));
    },
  );

  testWidgets(
    'conversation',
    (t) => conversation(t, '$_dir/coach_conversation'),
  );
  testWidgets(
    'conversation light',
    (t) => conversation(t, '$_dir/coach_conversation_light', light: true),
  );

  testWidgets('consent + thinking', (t) async {
    final never = Completer<AiChatResponse>();
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_consent',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([
            (r) => _tools(r, [
              ('k1', 'get_steps_summary', {'date': '2026-10-26'}),
            ]),
            (r) => never.future,
          ]),
        ),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        final ctl = c.read(coachControllerProvider.notifier);
        await _run(t, () => ctl.send('How many steps left today?'));
      },
    );
  });

  testWidgets('thinking', (t) async {
    final never = Completer<AiChatResponse>();
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_thinking',
      now: _evening,
      settle: const Duration(milliseconds: 9500),
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([
            (r) => _tools(r, [
              ('t1', 'get_workout_history', {}),
              ('t2', 'get_strength_progress', {'exercise': 'Bench press'}),
            ]),
            (r) => never.future,
          ]),
        ),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        await _run(t, () => seedDay(c, '2026-10-26'));
        final ctl = c.read(coachControllerProvider.notifier);
        unawaited(ctl.send('How is my bench progressing this month?'));
      },
    );
    // Let the client timeout fire so no timer is left pending.
    await t.pump(const Duration(minutes: 2));
  });

  testWidgets('error', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_error',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([
            (r) => throw const AiBackendException(
              'timeout',
              'The AI took too long to respond. You can retry.',
            ),
          ]),
        ),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        final ctl = c.read(coachControllerProvider.notifier);
        await _run(t, () => ctl.send('Plan a 45-min workout slot today'));
      },
    );
  });

  testWidgets('briefing', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_briefing',
      now: _morning,
      overrides: [
        // Unconfigured backend: the briefing is deterministic and local.
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        await _run(t, () => seedDay(c, '2026-10-26'));
        final ctl = c.read(coachControllerProvider.notifier);
        await _run(t, () => ctl.brief(BriefingMode.morning));
      },
    );
  });

  testWidgets('listening', (t) async {
    final stt = FakeRecognizer(partial: 'How much protein do I have left');
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_listening',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(stt: stt),
      ],
      prepare: (t) async {
        final c = _container(t);
        await _run(
          t,
          () => c
              .read(voiceSettingsRepositoryProvider)
              .save(const VoiceSettings(micExplained: true)),
        );
        await _settleAsync(t, 4);
        await t.tap(find.bySemanticsLabel('Talk to JARVIS'));
        await _settleAsync(t, 6);
      },
    );
  });

  testWidgets('speaking', (t) async {
    final tts = FakeSynth(hold: true);
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_speaking',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([
            (r) => _text(
              r,
              'Your next session is **Upper Push** tomorrow at 06:30 — 70 '
              'minutes, bench press first. Sleep by 22:45 and you will hit '
              'eight hours.',
            ),
          ]),
        ),
        ..._voiceFakes(tts: tts),
      ],
      prepare: (t) async {
        final c = _container(t);
        final ctl = c.read(coachControllerProvider.notifier);
        await _run(t, () => ctl.send("What's on tomorrow?"));
        unawaited(
          c
              .read(voiceControllerProvider.notifier)
              .speak(
                'Your next session is Upper Push tomorrow.',
                const VoiceSettings(),
              ),
        );
      },
    );
    tts.release();
  });

  testWidgets('mic explainer', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_mic_explainer',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(stt: FakeRecognizer(permission: false)),
      ],
      prepare: (t) async {
        await _settleAsync(t, 4);
        await t.tap(find.bySemanticsLabel('Talk to JARVIS'));
        await _settleAsync(t, 4);
      },
    );
  });

  testWidgets('voice settings', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_voice_settings',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        await _settleAsync(t, 4);
        await t.tap(find.bySemanticsLabel('Systems'));
        await _settleAsync(t, 12);
        await t.tap(find.text('Voice'));
        await _settleAsync(t, 6);
      },
    );
  });

  testWidgets('history', (t) async {
    await shotRoute(
      t,
      '/coach',
      '$_dir/coach_history',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([(r) => _text(r, 'Noted.')]),
        ),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        final c = _container(t);
        final ctl = c.read(coachControllerProvider.notifier);
        await _run(t, () async {
          await ctl.send('How did this week go?');
          ctl.newConversation();
          await ctl.send('Plan a 45-min workout slot today');
          ctl.newConversation();
          await ctl.brief(BriefingMode.evening);
        });
        await _settleAsync(t, 6);
        await t.tap(find.bySemanticsLabel('Conversations'));
        await _settleAsync(t, 10);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Messaging assistant
  // -------------------------------------------------------------------------

  List<Override> assistantShotOverrides(FakeAssistantPlatform platform) => [
    assistantPlatformProvider.overrideWithValue(platform),
    replyDrafterProvider.overrideWithValue(FakeDrafter()),
  ];

  Future<void> seedInbox(WidgetTester t) async {
    final c = ProviderScope.containerOf(t.element(find.byType(Scaffold).first));
    await _run(t, () async {
      await enableApp(c, whatsapp, label: 'WhatsApp', allowAi: true);
      await enableApp(c, sms, label: 'Messages');
      final now = DateTime.now();
      await c.read(ingestionServiceProvider).ingest([
        ev(
          text: 'Are we still on for dinner tonight? Call me when you can',
          at: now.subtract(const Duration(minutes: 4)),
          key: 'k1',
        ),
        ev(
          conv: 'shortcut-arjun',
          title: 'Arjun',
          sender: 'Arjun',
          text: 'Bro gym at 6 tomorrow? Leg day',
          at: now.subtract(const Duration(minutes: 38)),
          key: 'k2',
        ),
        ev(
          pkg: sms,
          conv: 'sms-coach',
          title: 'Coach Ravi',
          sender: 'Coach Ravi',
          text: 'Send me your squat video before Friday please.',
          at: now.subtract(const Duration(hours: 3)),
          key: 'k3',
        ),
      ]);
      final service = c.read(replyServiceProvider);
      final drafts = await c.read(assistantRepositoryProvider).allDrafts();
      const texts = {
        'shortcut-mom': 'Yes! 8 pm works. I will call you after my session.',
        'shortcut-arjun': 'In. 6 sharp — bring chalk.',
        'sms-coach': 'Will send it tonight, coach.',
      };
      for (final d in drafts) {
        await service.editDraft(d.id, texts[d.conversationKey] ?? 'On it.');
      }
    });
  }

  testWidgets('assistant inbox', (t) async {
    final platform = FakeAssistantPlatform(
      listenerEnabled: true,
      listenerConnected: true,
    );
    await shotRoute(
      t,
      '/assistant',
      '$_dir/assistant_inbox',
      now: _evening,
      scrolls: 3,
      overrides: assistantShotOverrides(platform),
      prepare: seedInbox,
    );
  });

  testWidgets('assistant draft editor', (t) async {
    final platform = FakeAssistantPlatform(
      listenerEnabled: true,
      listenerConnected: true,
    );
    await shotRoute(
      t,
      '/assistant',
      '$_dir/assistant_draft_editor',
      now: _evening,
      overrides: assistantShotOverrides(platform),
      prepare: (t) async {
        await seedInbox(t);
        await _settleAsync(t, 10);
        await t.tap(find.text('Mom').first);
        await _settleAsync(t, 14);
      },
    );
  });

  testWidgets('assistant killed light', (t) async {
    final platform = FakeAssistantPlatform();
    await shotRoute(
      t,
      '/assistant',
      '$_dir/assistant_killed_light',
      now: _evening,
      light: true,
      overrides: assistantShotOverrides(platform),
      prepare: (t) async {
        await seedInbox(t);
        final c = ProviderScope.containerOf(
          t.element(find.byType(Scaffold).first),
        );
        await _run(
          t,
          () => c.read(assistantControllerProvider).setKillSwitch(true),
        );
      },
    );
  });

  testWidgets('capabilities', (t) async {
    await shotRoute(
      t,
      '/settings/capabilities',
      '$_dir/assistant_capabilities',
      now: _evening,
      scrolls: 1,
      overrides: assistantShotOverrides(
        FakeAssistantPlatform(listenerEnabled: true, listenerConnected: true),
      ),
    );
  });

  testWidgets('assistant settings', (t) async {
    await shotRoute(
      t,
      '/assistant/settings',
      '$_dir/assistant_settings',
      now: _evening,
      scrolls: 1,
      overrides: assistantShotOverrides(FakeAssistantPlatform()),
      prepare: seedInbox,
    );
  });

  testWidgets('assistant audit', (t) async {
    await shotRoute(
      t,
      '/assistant/audit',
      '$_dir/assistant_audit',
      now: _evening,
      overrides: assistantShotOverrides(FakeAssistantPlatform()),
      prepare: seedInbox,
    );
  });

  // -------------------------------------------------------------------------
  // AI settings, memory, activity log
  // -------------------------------------------------------------------------

  testWidgets('ai settings', (t) async {
    await shotRoute(
      t,
      '/settings/ai',
      '$_dir/ai_settings',
      now: _evening,
      scrolls: 2,
      overrides: [
        aiBackendClientProvider.overrideWithValue(ShotBackend([])),
        ..._voiceFakes(),
      ],
      prepare: (t) async {
        await _settleAsync(t, 10);
        final c = ProviderScope.containerOf(
          t.element(find.byType(Scaffold).first),
        );
        c.read(providerProbesProvider.notifier)
          ..record('gemini', [
            const ProviderProbe(
              provider: 'gemini',
              alias: 'primary',
              ok: true,
              latencyMs: 1840,
            ),
            const ProviderProbe(
              provider: 'gemini',
              alias: 'secondary',
              ok: true,
              latencyMs: 2310,
            ),
          ])
          ..record('groq', [
            const ProviderProbe(
              provider: 'groq',
              alias: 'primary',
              ok: true,
              latencyMs: 412,
            ),
          ]);
      },
    );
  });

  testWidgets('ai memory', (t) async {
    await shotRoute(
      t,
      '/coach/memory',
      '$_dir/ai_memory',
      now: _evening,
      prepare: (t) async {
        final c = ProviderScope.containerOf(
          t.element(find.byType(Scaffold).first),
        );
        final repo = c.read(coachRepositoryProvider);
        await _run(t, () async {
          await repo.saveMemory(
            category: 'routine',
            content: 'Trains fasted at 6 am on weekdays',
            approved: true,
          );
          await repo.saveMemory(
            category: 'preference',
            content: 'Vegetarian; no eggs on Tuesdays',
            approved: true,
          );
          await repo.saveMemory(
            category: 'goal',
            content: 'Wants a 180 kg deadlift by March',
            approved: false,
          );
        });
      },
    );
  });

  testWidgets('ai history', (t) async {
    await shotRoute(
      t,
      '/coach/history',
      '$_dir/ai_history',
      now: _evening,
      overrides: [
        aiBackendClientProvider.overrideWithValue(
          ShotBackend([
            (r) => _tools(r, [
              ('h1', 'get_nutrition_summary', {'date': '2026-10-26'}),
              ('h2', 'get_steps_summary', {'date': '2026-10-26'}),
            ]),
            (r) => _tools(r, [
              (
                'h3',
                'record_recommendation',
                {
                  'kind': 'nutrition',
                  'content': 'Add a 30 g whey shake after evening sessions.',
                },
              ),
            ]),
            (r) => _text(r, 'Saved.'),
          ]),
        ),
      ],
      prepare: (t) async {
        final c = ProviderScope.containerOf(
          t.element(find.byType(Scaffold).first),
        );
        await _run(t, () => seedDay(c, '2026-10-26'));
        await _run(
          t,
          () => c.read(coachControllerProvider.notifier).send('Protein?'),
        );
      },
    );
  });
}
