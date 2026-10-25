import 'dart:async';
import 'dart:convert';

import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/assistant/domain/briefing_builder.dart';
import 'package:athlete_os/features/coach/agent/briefing.dart';
import 'package:athlete_os/features/coach/agent/coach_controller.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/coach_auth.dart';
import 'package:athlete_os/features/coach/data/coach_repository.dart';
import 'package:athlete_os/features/coach/tools/tool_args_validator.dart';
import 'package:athlete_os/features/coach/tools/tool_executor.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:athlete_os/features/coach/tools/tool_spec.dart';
import 'package:athlete_os/features/coach/voice/speech_ports.dart';
import 'package:athlete_os/features/coach/voice/voice_controller.dart';
import 'package:athlete_os/features/coach/voice/voice_settings.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';
import 'voice_fakes.dart';

/// Regression tests for the coach hardening review (Strava exclusion, tool
/// safety, resilience, consent and voice failures).
void main() {
  late AppDatabase db;

  setUp(() {
    db = newTestDb();
    addTearDown(db.close);
  });

  ProviderContainer container(
    AiBackendClient backend, {
    List<Override> extra = const [],
  }) {
    final c = ProviderContainer(
      overrides: [
        ...testOverrides(db, now: testNow),
        aiBackendClientProvider.overrideWithValue(backend),
        ...extra,
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  List<Map<String, Object?>> blocksOf(AiChatRequest r, String type) => [
    for (final m in r.messages)
      for (final b in (m['content'] as List).cast<Map<String, Object?>>())
        if (b['type'] == type) b,
  ];

  Future<Map<String, Object?>> run(
    String tool, [
    Map<String, Object?> args = const {},
  ]) => toolByName(tool)!.handler(toolContext(db), args);

  group('Strava never reaches the AI', () {
    Future<void> seedCardio() async {
      Future<void> add(
        String id, {
        required String source,
        String? name,
        String? rawJson,
        double km = 5,
        bool deleted = false,
      }) => db
          .into(db.cardioActivities)
          .insert(
            CardioActivitiesCompanion.insert(
              id: id,
              source: source,
              externalId: Value(id),
              name: Value(name),
              sportType: 'run',
              startAt: DateTime.utc(2026, 10, 25, 1),
              localDate: testToday,
              distanceM: Value(km * 1000),
              movingTimeS: const Value(1800),
              rawJson: Value(rawJson),
              deletedAt: Value(deleted ? DateTime.utc(2026, 10, 25, 2) : null),
            ),
          );
      // The Strava app writes its runs to Health Connect; the HC sync
      // imports them as source = health_connect.
      await add(
        'hc-strava',
        source: 'health_connect',
        name: 'Running · Strava',
        rawJson: jsonEncode({'source_app': 'com.strava', 'distance_m': 21097}),
        km: 21.097,
      );
      await add(
        'hc-strava-pkg',
        source: 'health_connect',
        name: 'Running · com.strava',
        km: 7.777,
      );
      await add('strava-1', source: 'strava', name: 'Morning Run', km: 9.999);
      await add(
        'hc-deleted',
        source: 'health_connect',
        km: 3.333,
        deleted: true,
      );
      await add(
        'hc-watch',
        source: 'health_connect',
        name: 'Running · Samsung Health',
        rawJson: jsonEncode({'source_app': 'com.sec.android.app.shealth'}),
        km: 5.5,
      );
    }

    test('HC-imported Strava sessions are excluded from every tool', () async {
      await seedCardio();
      final runs = await run('get_running_activities', {'sport_type': 'any'});
      final ids = [
        for (final a in runs['activities'] as List) (a as Map)['id'],
      ];
      expect(ids, ['hc-watch']);
      expect(runs['total_distance_km'], 5.5);

      final today = await run('get_today_dashboard');
      final cardio = (today['training'] as Map)['cardio'] as List;
      expect(cardio, hasLength(1));
      expect((cardio.single as Map)['distance_km'], 5.5);

      final week = await run('get_weekly_report');
      expect((week['runs'] as Map)['count'], 1);
      expect((week['runs'] as Map)['distance_km'], 5.5);

      final all = jsonEncode([runs, today, week]).toLowerCase();
      for (final leak in ['· strava', 'com.strava', '21.1', '7.78', '3.33']) {
        expect(all, isNot(contains(leak)));
      }
    });
  });

  group('tool-call ids', () {
    test('a repeated provider id cannot replay an earlier write', () async {
      await grantHealthConsent(db);
      // Providers without call ids get the same synthesised id every turn.
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'gemini-0-log_water', 'log_water', {
          'amount_ml': 250,
        }),
        (r) => FakeAiBackend.text(r, 'Logged.'),
        (r) => FakeAiBackend.toolCall(r, 'gemini-0-log_water', 'log_water', {
          'amount_ml': 300,
        }),
        (r) => FakeAiBackend.text(r, 'Logged again.'),
      ]);
      final c = container(backend);
      final ctl = c.read(coachControllerProvider.notifier);

      await ctl.send('I drank 250 ml');
      await ctl.approve();
      await ctl.send('and another 300 ml');
      // The second call must ask again, not replay the first result.
      final pending = c.read(coachControllerProvider).pending;
      expect(pending, isNotNull);
      expect(pending!.args['amount_ml'], 300);
      await ctl.approve();

      final water = await db.select(db.waterLogs).get();
      expect(water.map((w) => w.amountMl).toList()..sort(), [250, 300]);
      final keys = (await db.select(db.aiToolActions).get())
          .map((a) => a.idempotencyKey)
          .toSet();
      expect(keys, hasLength(2));

      // The wire history stays consistent: each result answers its call.
      final last = backend.requests.last;
      final callIds = blocksOf(last, 'tool_call').map((b) => b['id']).toList();
      final resultIds = blocksOf(
        last,
        'tool_result',
      ).map((b) => b['tool_call_id']).toList();
      expect(callIds, ['gemini-0-log_water', 'gemini-0-log_water_2']);
      expect(resultIds, callIds);
    });

    test('withUniqueToolCallIds is deterministic and leaves the rest', () {
      final out = withUniqueToolCallIds(
        [
          {'type': 'text', 'text': 'x'},
          {
            'type': 'tool_call',
            'id': 'a',
            'name': 'n',
            'provider_meta': {'k': 1},
          },
          {'type': 'tool_call', 'id': 'a', 'name': 'n'},
          {'type': 'tool_call', 'id': 'b', 'name': 'n'},
        ],
        {'b'},
      );
      expect(out.map((b) => b['id']), [null, 'a', 'a_2', 'b_2']);
      expect(out[1]['provider_meta'], {'k': 1});
    });
  });

  group('approval executes exactly once', () {
    late int runs;
    late Completer<void> gate;
    late ToolExecutor exec;

    setUp(() async {
      runs = 0;
      gate = Completer<void>();
      final slowWrite = ToolSpec(
        name: 'slow_write',
        description: 'test',
        inputSchema: S.object({}),
        isWrite: true,
        chipLabel: (a, n) => 'slow',
        handler: (ctx, args) async {
          runs++;
          await gate.future;
          return {'status': 'written'};
        },
      );
      exec = executorFor(db, tools: [slowWrite]);
      final first = await exec.execute(
        conversationId: 'c',
        toolCallId: 't',
        name: 'slow_write',
        args: const {},
      );
      expect(first.kind, ToolOutcomeKind.pendingConfirmation);
    });

    Future<ToolOutcome> approve() => exec.execute(
      conversationId: 'c',
      toolCallId: 't',
      name: 'slow_write',
      args: const {},
      confirmed: true,
    );

    test('concurrent approvals run the handler once', () async {
      final a = approve();
      final b = approve();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final results = await Future.wait([a, b]);
      expect(runs, 1);
      expect(results.first.replayed, isFalse);
      expect(results.last.replayed, isTrue);
      expect(results.last.result['status'], 'written');
    });

    test('a cancel racing an approval reports what really happened', () async {
      final a = approve();
      final r = exec.reject(
        conversationId: 'c',
        toolCallId: 't',
        name: 'slow_write',
        args: const {},
        reason: 'cancelled',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await a;
      final cancelled = await r;
      expect(runs, 1);
      expect(cancelled.replayed, isTrue);
      expect(cancelled.result['status'], 'written');
      final audit = await db.select(db.aiToolActions).getSingle();
      expect(audit.status, 'confirmed');
    });
  });

  group('tool arguments and dates', () {
    test('a millennia-wide range is rejected without expanding it', () async {
      await grantHealthConsent(db);
      final sw = Stopwatch()..start();
      final out = await executorFor(db).execute(
        conversationId: 'c',
        toolCallId: 'r',
        name: 'get_nutrition_summary',
        args: {'start_date': '0001-01-01', 'end_date': '9999-12-31'},
      );
      expect(out.isError, isTrue);
      expect(out.result['message'], contains('31 days'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('changing servings of an estimate rescales its nutrients', () async {
      await grantHealthConsent(db);
      await addFood(db, id: 'e1', date: testToday, kcal: 300, protein: 20);
      final out = await executorFor(db).execute(
        conversationId: 'c',
        toolCallId: 'u',
        name: 'update_food_entry',
        args: {'entry_id': 'e1', 'servings': 2},
        confirmed: true,
      );
      expect(out.isError, isFalse, reason: '${out.result}');
      final row = await db.select(db.foodLogEntries).getSingle();
      expect(row.servings, 2);
      expect(row.calories, 600);
      expect(row.proteinG, 40);
      expect(row.verification, 'estimate');
    });

    test('just after midnight "today" is the new local day', () async {
      await grantHealthConsent(db);
      final late = DateTime(2026, 10, 25, 23, 50);
      final early = DateTime(2026, 10, 26, 0, 10);
      await toolContext(db, now: late).water.add(400, at: late);
      final ctx = toolContext(db, now: early);
      final r = await toolByName('get_water_summary')!.handler(ctx, const {});
      final days = r['days'] as Map;
      expect(days.keys, ['2026-10-26']);
      expect((days['2026-10-26'] as Map)['total_ml'], 0);
      final y = await toolByName('get_water_summary')!
          .handler(ctx, const {'date': '2026-10-25'});
      expect(((y['days'] as Map)['2026-10-25'] as Map)['total_ml'], 400);
    });
  });

  group('resilience', () {
    test('a storage failure mid-turn ends with a retryable error, retry '
        'completes without duplicating the user message', () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'c1', 'get_competition_countdown'),
        (r) => FakeAiBackend.text(r, 'No competition saved.'),
      ]);
      final repo = _FlakyRepo(db)..failNextToolRow = true;
      final c = container(
        backend,
        extra: [coachRepositoryProvider.overrideWithValue(repo)],
      );
      final ctl = c.read(coachControllerProvider.notifier);
      await ctl.send('Days until my competition?');
      var s = c.read(coachControllerProvider);
      expect(s.busy, isFalse);
      expect(s.phase, CoachPhase.idle);
      expect(s.error?.code, 'internal');
      expect(s.canRetry, isTrue);

      await ctl.retry();
      s = c.read(coachControllerProvider);
      expect(s.error, isNull);
      expect(s.busy, isFalse);
      expect(
        s.entries.whereType<AssistantTextEntry>().last.text,
        'No competition saved.',
      );
      final users = (await db.select(db.aiMessages).get()).where(
        (m) => m.role == 'user',
      );
      expect(users, hasLength(1));
      // The tool ran once; the retry replayed it.
      expect(await db.select(db.aiToolActions).get(), hasLength(1));
    });

    test('a new message after an abandoned failed batch keeps history '
        'valid', () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'c1', 'get_competition_countdown'),
        (r) => FakeAiBackend.text(r, 'Fresh answer.'),
      ]);
      final repo = _FlakyRepo(db)..failNextToolRow = true;
      final c = container(
        backend,
        extra: [coachRepositoryProvider.overrideWithValue(repo)],
      );
      final ctl = c.read(coachControllerProvider.notifier);
      await ctl.send('Days until my competition?');
      expect(c.read(coachControllerProvider).error, isNotNull);
      // Instead of retrying, the user asks something else.
      expect(await ctl.send('Never mind. Hello?'), isTrue);
      final last = backend.requests.last;
      final calls = blocksOf(last, 'tool_call').map((b) => b['id']).toSet();
      final results = blocksOf(
        last,
        'tool_result',
      ).map((b) => b['tool_call_id']).toSet();
      expect(calls, {'c1'});
      expect(results, calls);
    });

    test('backend errors (429, timeout, offline) never leave the coach '
        'busy', () async {
      for (final e in const [
        AiBackendException('rate_limited', 'Too many requests.'),
        AiBackendException('timeout', 'Too slow.'),
        AiBackendException('network', 'Offline.'),
      ]) {
        final c = container(FakeAiBackend([(r) => throw e]));
        final ctl = c.read(coachControllerProvider.notifier);
        await ctl.send('hello ${e.code}');
        final s = c.read(coachControllerProvider);
        expect(s.busy, isFalse, reason: e.code);
        expect(s.error?.code, e.code);
        expect(s.canRetry, isTrue);
        expect(s.entries.whereType<UserTextEntry>(), hasLength(1));
      }
    });

    test('signed out: the anonymous sign-in is retried on send', () async {
      final auth = _FakeAuth();
      final backend = _AuthBackend(auth);
      final c = container(
        backend,
        extra: [coachAuthProvider.overrideWithValue(auth)],
      );
      expect(
        await c.read(coachControllerProvider.notifier).send('hello'),
        isTrue,
      );
      expect(auth.anonymousCalls, 1);
      expect(backend.requests, hasLength(1));
      expect(c.read(coachControllerProvider).error, isNull);
    });

    test('signed out and sign-in fails: honest error, not busy', () async {
      final auth = _FakeAuth(fail: true);
      final backend = _AuthBackend(auth);
      final c = container(
        backend,
        extra: [coachAuthProvider.overrideWithValue(auth)],
      );
      final ok = await c.read(coachControllerProvider.notifier).send('hello');
      final s = c.read(coachControllerProvider);
      expect(ok, isFalse);
      expect(s.busy, isFalse);
      expect(s.error?.code, 'unauthorized');
      expect(s.error?.message, contains("Couldn't sign in"));
      expect(backend.requests, isEmpty);
      expect(await db.select(db.aiMessages).get(), isEmpty);
    });

    test('a busy coach refuses (and reports) a second message', () async {
      final hold = Completer<AiChatResponse>();
      final c = container(FakeAiBackend([(r) => hold.future]));
      final ctl = c.read(coachControllerProvider.notifier);
      final first = ctl.send('one');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await ctl.send('two'), isFalse);
      hold.complete(
        const AiChatResponse(
          requestId: 'x',
          content: [
            {'type': 'text', 'text': 'ok'},
          ],
          stopReason: 'end_turn',
        ),
      );
      expect(await first, isTrue);
    });
  });

  group('consent', () {
    test('revoking health consent withholds earlier health results', () async {
      await grantHealthConsent(db);
      await addFood(db, id: 'f', date: testToday, kcal: 777, name: 'SecretDal');
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'n1', 'get_nutrition_summary'),
        (r) => FakeAiBackend.text(r, 'You had dal.'),
        (r) => FakeAiBackend.text(r, 'Hello.'),
      ]);
      final c = container(backend);
      final ctl = c.read(coachControllerProvider.notifier);
      await ctl.send('What did I eat today?');
      expect(jsonEncode(backend.requests[1].toJson()), contains('SecretDal'));

      await SettingsRepository(db).set(SettingKeys.aiHealthConsent, false);
      await ctl.send('Thanks. Anything else?');
      final wire = jsonEncode(backend.requests.last.toJson());
      expect(wire, isNot(contains('SecretDal')));
      expect(wire, contains('withheld'));
    });
  });

  test('briefing polish never sends notification contact names', () {
    final inputs = CoachBriefingInputs(
      now: DateTime(2026, 10, 25, 8),
      lines: const [
        BriefingLine(BriefingKind.steps, '2,000 steps to go (8,000 of 10,000)'),
        BriefingLine(
          BriefingKind.unanswered,
          'Possibly unanswered: Priya Sharma, Dad',
        ),
      ],
    );
    final split = splitBriefingForAi(BriefingMode.morning, inputs);
    expect(split.forAi, contains('2,000'));
    expect(split.forAi, isNot(contains('Priya')));
    expect(split.forAi, isNot(contains('Dad')));
    expect(split.deviceOnly, contains('Priya Sharma, Dad'));
    // Removing the line does not change the task count sentence.
    expect(
      split.forAi.split('\n').last,
      composeBriefing(BriefingMode.morning, inputs).split('\n').last,
    );
  });

  test('a failing TTS engine does not throw or stay "speaking"', () async {
    final c = ProviderContainer(
      overrides: [
        speechRecognizerProvider.overrideWithValue(FakeRecognizer()),
        speechSynthProvider.overrideWithValue(_BrokenSynth()),
      ],
    );
    addTearDown(c.dispose);
    await c
        .read(voiceControllerProvider.notifier)
        .speak('You have **40 g** of protein left.', const VoiceSettings());
    expect(c.read(voiceControllerProvider).phase, VoicePhase.idle);
  });

  test('clock is injected: FixedClock drives the tool date', () {
    final ctx = toolContext(db, now: DateTime(2026, 1, 1, 0, 0, 1));
    expect(ctx.today, '2026-01-01');
    expect(LocalDates.key(ctx.now), ctx.today);
  });
}

/// Fails the next insert of a `tool` row once (simulated storage error).
class _FlakyRepo extends CoachRepository {
  _FlakyRepo(super.db);
  bool failNextToolRow = false;

  @override
  Future<AiMessage> addMessage(
    String conversationId,
    String role,
    List<Map<String, Object?>> blocks, {
    String? provider,
    String? model,
    int? inputTokens,
    int? outputTokens,
  }) {
    if (role == 'tool' && failNextToolRow) {
      failNextToolRow = false;
      throw StateError('disk I/O error');
    }
    return super.addMessage(
      conversationId,
      role,
      blocks,
      provider: provider,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }
}

class _FakeAuth implements CoachAuth {
  _FakeAuth({this.fail = false});
  final bool fail;
  bool signedIn = false;
  int anonymousCalls = 0;

  @override
  CoachAuthState get current =>
      CoachAuthState(configured: true, userId: signedIn ? 'u1' : null);
  @override
  Stream<CoachAuthState> changes() => Stream.value(current);
  @override
  Future<void> signInAnonymously() async {
    anonymousCalls++;
    if (fail) throw StateError('offline');
    signedIn = true;
  }

  @override
  Future<void> sendEmailCode(String email) async {}
  @override
  Future<void> verifyEmailCode(String email, String code) async {}
  @override
  Future<void> signOut() async => signedIn = false;
}

/// Ready only while [auth] has a session (like `SupabaseAiBackend`).
class _AuthBackend extends FakeAiBackend {
  _AuthBackend(this.auth) : super([]);
  final _FakeAuth auth;

  @override
  AiBackendState get state =>
      auth.signedIn ? AiBackendState.ready : AiBackendState.signedOut;
}

class _BrokenSynth extends FakeSynth {
  @override
  Future<List<TtsVoice>> voices() async => throw StateError('no engine');

  @override
  Future<void> speak(
    String text, {
    void Function(int start, int end)? onProgress,
  }) async => throw StateError('engine died');
}
