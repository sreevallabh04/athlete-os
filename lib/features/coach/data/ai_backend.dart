import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/util/redact.dart';
import 'ai_preferences.dart';
import 'coach_auth.dart';

/// One provider-neutral model call (see docs/AI_AGENT.md for the contract).
class AiChatRequest {
  const AiChatRequest({
    required this.requestId,
    required this.conversationId,
    required this.system,
    required this.messages,
    required this.tools,
    required this.preferences,
  });

  /// Idempotency key for this model call; reused verbatim on retry so the
  /// server returns the cached response instead of paying twice.
  final String requestId;
  final String? conversationId;
  final String system;
  final List<Map<String, Object?>> messages;
  final List<Map<String, Object?>> tools;
  final AiPreferences preferences;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'conversation_id': conversationId,
    'system': system,
    'messages': messages,
    'tools': tools,
    'preferences': preferences.toWire(),
  };
}

class AiChatResponse {
  const AiChatResponse({
    required this.requestId,
    required this.content,
    required this.stopReason,
    this.inputTokens,
    this.outputTokens,
    this.costUsd,
    this.provider,
    this.model,
    this.meta = const {},
  });

  final String requestId;

  /// Normalised blocks: text | tool_call | opaque.
  final List<Map<String, Object?>> content;
  final String stopReason;
  final int? inputTokens;
  final int? outputTokens;
  final double? costUsd;
  final String? provider;
  final String? model;
  final Map<String, Object?> meta;

  List<Map<String, Object?>> get toolCalls =>
      content.where((b) => b['type'] == 'tool_call').toList();

  String get text => content
      .where((b) => b['type'] == 'text')
      .map((b) => b['text'] as String? ?? '')
      .join('\n')
      .trim();

  factory AiChatResponse.fromJson(Map<String, Object?> json) {
    final usage = (json['usage'] as Map?)?.cast<String, Object?>() ?? {};
    final content = <Map<String, Object?>>[];
    for (final b in (json['content'] as List? ?? const [])) {
      if (b is! Map) continue;
      final block = b.cast<String, Object?>();
      final type = block['type'];
      if (type == 'text' && block['text'] is String) {
        content.add({'type': 'text', 'text': block['text']});
      } else if (type == 'tool_call' &&
          block['id'] is String &&
          block['name'] is String) {
        content.add({
          'type': 'tool_call',
          'id': block['id'],
          'name': block['name'],
          'arguments': block['arguments'] is Map
              ? (block['arguments'] as Map).cast<String, Object?>()
              : <String, Object?>{},
          'provider_meta': ?block['provider_meta'],
        });
      } else if (type == 'opaque') {
        content.add(block);
      }
    }
    return AiChatResponse(
      requestId: json['request_id'] as String? ?? '',
      content: content,
      stopReason: json['stop_reason'] as String? ?? 'other',
      inputTokens: (usage['input_tokens'] as num?)?.toInt(),
      outputTokens: (usage['output_tokens'] as num?)?.toInt(),
      costUsd: (usage['cost_usd'] as num?)?.toDouble(),
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      meta: (json['meta'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }
}

/// User-presentable failure. [message] is already redacted.
class AiBackendException implements Exception {
  const AiBackendException(this.code, this.message, {this.retryAfter});

  final String code;
  final String message;
  final Duration? retryAfter;

  bool get retryable => const {
    'rate_limited',
    'timeout',
    'upstream_error',
    'providers_unavailable',
    'internal',
    'network',
  }.contains(code);

  @override
  String toString() => 'AiBackendException($code): $message';
}

enum AiBackendState {
  /// No Supabase project configured in this build.
  unconfigured,

  /// Backend configured but the user has not signed in.
  signedOut,
  ready,
}

/// Talks to the `ai-chat` / `ai-status` edge functions. Provider API keys
/// never touch the device.
abstract interface class AiBackendClient {
  AiBackendState get state;
  Future<AiChatResponse> chat(AiChatRequest request);
  Future<Map<String, Object?>> status();
  Future<Map<String, Object?>> testProviders({String? provider});
}

/// Used when the build has no Supabase config. It never fabricates answers.
class UnconfiguredAiBackend implements AiBackendClient {
  const UnconfiguredAiBackend({this.signedOut = false});
  final bool signedOut;

  @override
  AiBackendState get state =>
      signedOut ? AiBackendState.signedOut : AiBackendState.unconfigured;

  AiBackendException get _error => signedOut
      ? const AiBackendException(
          'unauthorized',
          'Sign in to the AI backend in AI settings to use the coach.',
        )
      : const AiBackendException(
          'awaiting_credentials',
          'The AI backend is not configured yet. Open AI settings for the '
              'setup guide.',
        );

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async => throw _error;

  @override
  Future<Map<String, Object?>> status() async => throw _error;

  @override
  Future<Map<String, Object?>> testProviders({String? provider}) async =>
      throw _error;
}

class SupabaseAiBackend implements AiBackendClient {
  SupabaseAiBackend(this._client);
  final SupabaseClient _client;

  @override
  AiBackendState get state => _client.auth.currentUser == null
      ? AiBackendState.signedOut
      : AiBackendState.ready;

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    final json = await _invoke(
      'ai-chat',
      request.toJson(),
      timeout: Duration(milliseconds: request.preferences.timeoutMs + 15000),
    );
    return AiChatResponse.fromJson(json);
  }

  @override
  Future<Map<String, Object?>> status() =>
      _invoke('ai-status', const {'action': 'status'});

  @override
  Future<Map<String, Object?>> testProviders({String? provider}) => _invoke(
    'ai-status',
    {'action': 'test', 'provider': ?provider},
    timeout: const Duration(seconds: 60),
  );

  Future<Map<String, Object?>> _invoke(
    String fn,
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_client.auth.currentUser == null) {
      throw const AiBackendException(
        'unauthorized',
        'Sign in to the AI backend in AI settings first.',
      );
    }
    try {
      // Refreshes an expired access token before calling the function.
      final session = await _client.auth.getSession();
      final res = await _client.functions
          .invoke(
            fn,
            body: body,
            headers: {
              if (session != null)
                'Authorization': 'Bearer ${session.accessToken}',
            },
          )
          .timeout(timeout);
      final data = res.data;
      if (data is Map) return data.cast<String, Object?>();
      throw const AiBackendException(
        'internal',
        'The AI backend returned an unexpected response.',
      );
    } on AiBackendException {
      rethrow;
    } on FunctionException catch (e) {
      throw mapFunctionError(e.status, e.details);
    } on TimeoutException {
      throw const AiBackendException(
        'timeout',
        'The AI took too long to respond. You can retry.',
      );
    } catch (e) {
      // Type only: a parse error's text can embed the response body (the
      // user's health data / the model's answer); secret redaction does not
      // cover that.
      debugPrint('AI backend error: ${e.runtimeType}');
      throw const AiBackendException(
        'network',
        "Couldn't reach the AI backend. Check your connection and retry.",
      );
    }
  }
}

/// Maps an edge-function error body to a friendly, redacted exception.
AiBackendException mapFunctionError(int status, Object? details) {
  String? code;
  String? message;
  Duration? retryAfter;
  final err = details is Map ? details['error'] : null;
  if (err is Map) {
    code = err['code'] as String?;
    message = err['message'] as String?;
    final s = err['retry_after_s'];
    if (s is num) retryAfter = Duration(seconds: s.ceil());
  }
  code ??= switch (status) {
    0 => 'network',
    401 || 403 => 'unauthorized',
    402 => 'budget_exceeded',
    409 => 'conflict',
    429 => 'rate_limited',
    400 => 'invalid_request',
    503 => 'providers_unavailable',
    504 => 'timeout',
    _ => 'upstream_error',
  };
  final fallback = switch (code) {
    'network' => "Couldn't reach the AI backend. Check your connection.",
    'unauthorized' =>
      'Your AI backend session expired. Sign in again in AI '
          'settings.',
    'budget_exceeded' =>
      'The monthly AI budget has been reached. You can '
          'raise it in AI settings.',
    'rate_limited' => 'Too many requests right now. Try again shortly.',
    'no_provider_configured' =>
      'No AI provider key is configured on the '
          'server yet.',
    'providers_unavailable' =>
      'All AI providers are unavailable right now. '
          'Try again in a minute.',
    'timeout' => 'The AI took too long to respond. You can retry.',
    'invalid_request' => 'The request was rejected by the AI backend.',
    _ => 'The AI service had a problem. You can retry.',
  };
  final text = (message == null || message.trim().isEmpty)
      ? fallback
      : redactSecrets(message.trim());
  return AiBackendException(
    code,
    text.length > 300 ? '${text.substring(0, 300)}…' : text,
    retryAfter: retryAfter,
  );
}

final aiBackendClientProvider = Provider<AiBackendClient>((ref) {
  // Rebuild when the auth state changes so `state` is current.
  ref.watch(coachAuthStateProvider);
  if (!CoachSupabase.ready) {
    return const UnconfiguredAiBackend();
  }
  return SupabaseAiBackend(Supabase.instance.client);
});

final aiBackendStateProvider = Provider<AiBackendState>(
  (ref) => ref.watch(aiBackendClientProvider).state,
);
