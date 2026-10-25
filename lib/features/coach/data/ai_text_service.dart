import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'ai_backend.dart';
import 'ai_preferences.dart';

/// Result of a single-shot text completion.
class AiTextResult {
  const AiTextResult({
    required this.text,
    this.provider,
    this.model,
    this.inputTokens,
    this.outputTokens,
    this.costUsd,
    this.stopReason = 'end_turn',
  });

  final String text;
  final String? provider;
  final String? model;
  final int? inputTokens;
  final int? outputTokens;
  final double? costUsd;
  final String stopReason;

  bool get truncated => stopReason == 'max_tokens';
}

/// An inline image for [AiTextService.structured]. Only image-capable
/// providers receive it (the server never routes images to text-only models).
class AiImage {
  const AiImage(this.bytes, {this.mimeType = 'image/jpeg'});
  final Uint8List bytes;
  final String mimeType;

  /// Server limit on decoded bytes (see `LIMITS.imageBytes` in validate.ts).
  static const maxBytes = 1024 * 1024;
  static const supportedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
}

/// Small reusable façade over the `ai-chat` edge function for one-shot,
/// non-agentic calls (reply drafts, food estimates, summaries).
///
/// It sends no tools for [complete] and exactly one tool for [structured],
/// whose arguments are returned unexecuted. Errors surface as
/// [AiBackendException] with a redacted, user-presentable message.
class AiTextService {
  AiTextService(
    this._backend,
    this._loadPreferences, {
    String Function()? newId,
  }) : _newId = newId ?? (() => const Uuid().v4().replaceAll('-', ''));

  final AiBackendClient _backend;
  final Future<AiPreferences> Function() _loadPreferences;
  final String Function() _newId;

  AiBackendState get state => _backend.state;
  bool get isConfigured => _backend.state != AiBackendState.unconfigured;

  /// Plain text completion: `system` + one user message, no tools.
  Future<AiTextResult> complete({
    required String system,
    required String user,
    int maxTokens = 1024,
  }) async {
    final res = await _send(
      system: system,
      content: [
        {'type': 'text', 'text': user},
      ],
      tools: const [],
      maxTokens: maxTokens,
    );
    return AiTextResult(
      text: res.text,
      provider: res.provider,
      model: res.model,
      inputTokens: res.inputTokens,
      outputTokens: res.outputTokens,
      costUsd: res.costUsd,
      stopReason: res.stopReason,
    );
  }

  /// Asks the model to call [toolName] (described by the JSON [schema]) and
  /// returns its arguments, or `null` when the model answered without calling
  /// it. The tool is never executed here.
  Future<Map<String, dynamic>?> structured({
    required String system,
    required String user,
    required String toolName,
    required Map<String, Object?> schema,
    String toolDescription = 'Return the result in structured form.',
    AiImage? image,
    int maxTokens = 2048,
  }) async {
    if (image != null) {
      if (!AiImage.supportedMimeTypes.contains(image.mimeType)) {
        throw const AiBackendException(
          'invalid_request',
          'Unsupported image type. Use a JPEG, PNG or WebP photo.',
        );
      }
      if (image.bytes.length > AiImage.maxBytes) {
        throw const AiBackendException(
          'invalid_request',
          'The photo is too large (over 1 MB). Retake it or pick a smaller one.',
        );
      }
    }
    final res = await _send(
      system: system,
      content: [
        {'type': 'text', 'text': user},
        if (image != null)
          {
            'type': 'image',
            'media_type': image.mimeType,
            'data': base64Encode(image.bytes),
          },
      ],
      tools: [
        {
          'name': toolName,
          'description': toolDescription,
          'input_schema': schema,
        },
      ],
      maxTokens: maxTokens,
    );
    for (final call in res.toolCalls) {
      if (call['name'] == toolName) {
        final args = call['arguments'];
        if (args is Map) return args.cast<String, dynamic>();
      }
    }
    return null;
  }

  Future<AiChatResponse> _send({
    required String system,
    required List<Map<String, Object?>> content,
    required List<Map<String, Object?>> tools,
    required int maxTokens,
  }) async {
    final prefs = await _loadPreferences();
    return _backend.chat(
      AiChatRequest(
        requestId: 'txt_${_newId()}',
        conversationId: null,
        system: system,
        messages: [
          {'role': 'user', 'content': content},
        ],
        tools: tools,
        // The user's provider/model choice, budget and timeout still apply.
        preferences: prefs.copyWith(maxTokens: maxTokens.clamp(256, 16000)),
      ),
    );
  }
}

final aiTextServiceProvider = Provider<AiTextService>(
  (ref) => AiTextService(
    ref.watch(aiBackendClientProvider),
    () => ref.read(aiPreferencesRepositoryProvider).load(),
  ),
);
