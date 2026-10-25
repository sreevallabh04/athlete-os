import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  test('parses normalised responses and ignores malformed blocks', () {
    final r = AiChatResponse.fromJson({
      'request_id': 'req-12345678',
      'content': [
        {
          'type': 'opaque',
          'provider': 'anthropic',
          'data': {'type': 'thinking'},
        },
        {'type': 'text', 'text': 'Hi'},
        {
          'type': 'tool_call',
          'id': 't1',
          'name': 'get_today_dashboard',
          'arguments': {'a': 1},
          'provider_meta': {'thought_signature': 'sig'},
        },
        {'type': 'tool_call', 'name': 'missing_id'},
        'garbage',
      ],
      'stop_reason': 'tool_use',
      'usage': {'input_tokens': 120, 'output_tokens': 30, 'cost_usd': 0.0005},
      'provider': 'gemini',
      'model': 'gemini-3.8-flash',
      'meta': {'cached': true},
    });
    expect(r.content, hasLength(3));
    expect(r.toolCalls.single['provider_meta'], {'thought_signature': 'sig'});
    expect(r.text, 'Hi');
    expect(r.inputTokens, 120);
    expect(r.costUsd, 0.0005);
    expect(r.meta['cached'], true);
  });

  test('maps edge-function errors to friendly, redacted messages', () {
    final rl = mapFunctionError(429, {
      'error': {
        'code': 'rate_limited',
        'message': 'Slow down',
        'retry_after_s': 12,
      },
    });
    expect(rl.code, 'rate_limited');
    expect(rl.retryAfter, const Duration(seconds: 12));
    expect(rl.retryable, isTrue);

    final budget = mapFunctionError(402, null);
    expect(budget.code, 'budget_exceeded');
    expect(budget.retryable, isFalse);
    expect(budget.message, contains('budget'));

    final leaky = mapFunctionError(502, {
      'error': {
        'code': 'upstream_error',
        'message': 'failed with key sk-ant-api03-abcdefghijklmnopqrstuvwxyz',
      },
    });
    expect(leaky.message, isNot(contains('abcdefghijklmnop')));
    expect(mapFunctionError(0, 'socket').code, 'network');
  });

  test('unconfigured backend never produces an answer', () async {
    const b = UnconfiguredAiBackend();
    expect(b.state, AiBackendState.unconfigured);
    await expectLater(
      b.chat(
        const AiChatRequest(
          requestId: 'r-12345678',
          conversationId: null,
          system: '',
          messages: [],
          tools: [],
          preferences: AiPreferences(),
        ),
      ),
      throwsA(isA<AiBackendException>()),
    );
  });

  test('preferences persist under ai.* keys and are clamped', () async {
    final db = newTestDb();
    addTearDown(db.close);
    final settings = SettingsRepository(db);
    final repo = AiPreferencesRepository(settings);
    expect((await repo.load()).maxTokens, 4096);
    await repo.save(
      const AiPreferences(
        primaryProvider: 'gemini',
        model: 'gemini-3.8-flash',
        fallbackProviders: ['anthropic'],
        maxTokens: 2048,
        timeoutMs: 30000,
        maxRetries: 1,
        monthlyBudgetUsd: 5,
      ),
    );
    final p = await repo.load();
    expect(p.primaryProvider, 'gemini');
    expect(p.fallbackProviders, ['anthropic']);
    expect(p.toWire()['max_tokens'], 2048);
    expect(await settings.get<String>('ai.model'), 'gemini-3.8-flash');
    await settings.set(AiSettingKeys.maxTokens, 999999);
    await settings.set(AiSettingKeys.primaryProvider, 'evil');
    final clamped = await repo.load();
    expect(clamped.maxTokens, 16000);
    expect(clamped.primaryProvider, isNull);
  });
}
