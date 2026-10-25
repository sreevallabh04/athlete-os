import 'dart:convert';
import 'dart:typed_data';

import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/data/ai_text_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coach_test_utils.dart';

AiTextService _service(FakeAiBackend backend, {AiPreferences? prefs}) =>
    AiTextService(
      backend,
      () async => prefs ?? const AiPreferences(primaryProvider: 'gemini'),
      newId: () => 'fixedid0001',
    );

void main() {
  test('complete sends system + one user text block and no tools', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.text(r, 'Very good, Sreevallabh.'),
    ]);
    final res = await _service(backend)
        .complete(system: 'Be brief.', user: 'Draft a reply', maxTokens: 300);

    expect(res.text, 'Very good, Sreevallabh.');
    expect(res.provider, 'anthropic');
    expect(res.truncated, isFalse);
    final req = backend.requests.single;
    final wire = req.toJson();
    expect(wire['request_id'], 'txt_fixedid0001');
    expect(wire['system'], 'Be brief.');
    expect(wire['tools'], isEmpty);
    expect(wire['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Draft a reply'},
        ],
      },
    ]);
    final prefs = wire['preferences']! as Map<String, Object?>;
    expect(prefs['max_tokens'], 300);
    expect(prefs['primary_provider'], 'gemini');
  });

  test('maxTokens is clamped to the server range', () async {
    final backend = FakeAiBackend([(r) => FakeAiBackend.text(r, 'x')]);
    await _service(backend).complete(system: 's', user: 'u', maxTokens: 10);
    final prefs =
        backend.requests.single.toJson()['preferences']!
            as Map<String, Object?>;
    expect(prefs['max_tokens'], 256);
  });

  test('structured returns the named tool call arguments unexecuted', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'c1', 'classify', {
        'label': 'positive',
        'score': 0.9,
      }),
    ]);
    final args = await _service(backend).structured(
      system: 'Classify.',
      user: 'I love it',
      toolName: 'classify',
      schema: const {
        'type': 'object',
        'properties': {
          'label': {'type': 'string'},
        },
      },
    );
    expect(args, {'label': 'positive', 'score': 0.9});
    final tools = backend.requests.single.tools;
    expect(tools.single['name'], 'classify');
    expect(tools.single['input_schema'], isA<Map<String, Object?>>());
  });

  test('structured returns null when the model answers in prose', () async {
    final backend = FakeAiBackend([(r) => FakeAiBackend.text(r, 'Positive')]);
    final args = await _service(backend).structured(
      system: 's',
      user: 'u',
      toolName: 'classify',
      schema: const {'type': 'object'},
    );
    expect(args, isNull);
  });

  test(
    'structured sends an image block as base64 and enforces limits',
    () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'c1', 't', {'ok': true}),
      ]);
      final svc = _service(backend);
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      await svc.structured(
        system: 's',
        user: 'u',
        toolName: 't',
        schema: const {'type': 'object'},
        image: AiImage(bytes),
      );
      final content =
          (backend.requests.single.messages.single['content']! as List)
              .cast<Map<String, Object?>>();
      expect(content[1], {
        'type': 'image',
        'media_type': 'image/jpeg',
        'data': base64Encode(bytes),
      });

      expect(
        () => svc.structured(
          system: 's',
          user: 'u',
          toolName: 't',
          schema: const {'type': 'object'},
          image: AiImage(Uint8List(AiImage.maxBytes + 1)),
        ),
        throwsA(
          isA<AiBackendException>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(
        () => svc.structured(
          system: 's',
          user: 'u',
          toolName: 't',
          schema: const {'type': 'object'},
          image: AiImage(bytes, mimeType: 'image/gif'),
        ),
        throwsA(isA<AiBackendException>()),
      );
      expect(backend.requests, hasLength(1));
    },
  );

  test('backend errors propagate as AiBackendException', () async {
    final backend = FakeAiBackend([
      (_) => throw const AiBackendException('budget_exceeded', 'Budget hit.'),
    ]);
    expect(
      () => _service(backend).complete(system: 's', user: 'u'),
      throwsA(
        isA<AiBackendException>().having((e) => e.message, 'm', 'Budget hit.'),
      ),
    );
  });

  test('state mirrors the backend', () {
    final svc = AiTextService(
      const UnconfiguredAiBackend(),
      () async => const AiPreferences(),
    );
    expect(svc.isConfigured, isFalse);
    expect(svc.state, AiBackendState.unconfigured);
    final signedOut = AiTextService(
      const UnconfiguredAiBackend(signedOut: true),
      () async => const AiPreferences(),
    );
    expect(signedOut.isConfigured, isTrue);
    expect(signedOut.state, AiBackendState.signedOut);
  });
}
