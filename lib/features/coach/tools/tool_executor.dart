import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/util/ids.dart';
import '../../../core/util/redact.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import 'tool_args_validator.dart';
import 'tool_spec.dart';

enum ToolOutcomeKind {
  /// The tool ran (or its stored result was replayed); send [result] back.
  result,

  /// A write tool is waiting for the user to approve it.
  pendingConfirmation,

  /// The tool needs a consent the user has not granted yet.
  consentRequired,
}

class ToolOutcome {
  const ToolOutcome._({
    required this.kind,
    required this.toolName,
    required this.toolCallId,
    required this.args,
    this.result = const {},
    this.isError = false,
    this.replayed = false,
    this.consent,
  });

  final ToolOutcomeKind kind;
  final String toolName;
  final String toolCallId;
  final Map<String, Object?> args;
  final Map<String, Object?> result;
  final bool isError;

  /// True when the stored result of an earlier execution was returned.
  final bool replayed;
  final ToolConsent? consent;

  /// Normalised `tool_result` block for the backend wire format.
  Map<String, Object?> toResultBlock() {
    var content = jsonEncode(result);
    if (content.length > maxResultChars) {
      content = jsonEncode({
        'error': 'result_too_large',
        'message':
            'Result exceeded the size limit; use a narrower date range '
            'or a smaller limit.',
      });
    }
    return {
      'type': 'tool_result',
      'tool_call_id': toolCallId,
      'name': toolName,
      'content': content,
      'is_error': isError || content.contains('"result_too_large"'),
    };
  }

  /// Keeps tool results well under the backend's 16 000-char block limit.
  static const maxResultChars = 12000;
}

/// Runs agent tools locally with validation, consent gating, write
/// confirmation, idempotency and an audit trail in `ai_tool_actions`.
///
/// Idempotency key = `conversationId:toolCallId`. If a call with that key has
/// already finished (ok / error / confirmed / rejected), its stored result is
/// returned and the handler is NOT run again, so a retried model round can
/// never duplicate a side effect.
class ToolExecutor {
  ToolExecutor({
    required this.db,
    required this.settings,
    required List<ToolSpec> tools,
    required this.contextFor,
    this.validator = const ToolArgsValidator(),
    this.timeout = const Duration(seconds: 20),
  }) : tools = {for (final t in tools) t.name: t};

  final AppDatabase db;
  final SettingsRepository settings;
  final Map<String, ToolSpec> tools;
  final ToolContext Function(String conversationId, String toolCallId)
  contextFor;
  final ToolArgsValidator validator;
  final Duration timeout;

  static const _finalStatuses = {'ok', 'error', 'confirmed', 'rejected'};

  /// Tail of the operation chain per idempotency key. Calls for the same key
  /// run one after another, so a double-tapped approval, a retry racing an
  /// approval, or a cancel racing an approval sees the first call's final
  /// audit row and replays it instead of running the handler a second time.
  final Map<String, Future<void>> _chains = {};

  Future<T> _serialized<T>(String key, Future<T> Function() op) {
    final prev = _chains[key] ?? Future<void>.value();
    final result = prev.then((_) => op());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _chains[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_chains[key], tail)) _chains.remove(key);
      }),
    );
    return result;
  }

  static String keyFor(String conversationId, String toolCallId) =>
      '$conversationId:$toolCallId';

  Future<AiToolAction?> _audit(String key) => (db.select(
    db.aiToolActions,
  )..where((a) => a.idempotencyKey.equals(key))).getSingleOrNull();

  Future<bool> hasConsent(ToolConsent consent) async {
    switch (consent) {
      case ToolConsent.none:
        return true;
      case ToolConsent.health:
        return (await settings.get<bool>(SettingKeys.aiHealthConsent)) ?? false;
      case ToolConsent.journal:
        return (await settings.get<bool>(SettingKeys.aiJournalConsent)) ??
            false;
    }
  }

  /// Executes (or replays) one tool call.
  ///
  /// Write tools return [ToolOutcomeKind.pendingConfirmation] until called
  /// again with [confirmed] = true. [editedArgs] replaces the model's
  /// arguments when the user edited them on the confirmation card.
  Future<ToolOutcome> execute({
    required String conversationId,
    required String toolCallId,
    required String name,
    required Map<String, Object?> args,
    bool confirmed = false,
    Map<String, Object?>? editedArgs,
  }) {
    final key = keyFor(conversationId, toolCallId);
    return _serialized(
      key,
      () => _execute(
        key: key,
        conversationId: conversationId,
        toolCallId: toolCallId,
        name: name,
        args: args,
        confirmed: confirmed,
        editedArgs: editedArgs,
      ),
    );
  }

  Future<ToolOutcome> _execute({
    required String key,
    required String conversationId,
    required String toolCallId,
    required String name,
    required Map<String, Object?> args,
    required bool confirmed,
    required Map<String, Object?>? editedArgs,
  }) async {
    final existing = await _audit(key);
    if (existing != null && _finalStatuses.contains(existing.status)) {
      return ToolOutcome._(
        kind: ToolOutcomeKind.result,
        toolName: name,
        toolCallId: toolCallId,
        args: _decodeArgs(existing.argsJson),
        result: _decodeResult(existing.resultSummary),
        isError: existing.status == 'error',
        replayed: true,
      );
    }

    final spec = tools[name];
    if (spec == null) {
      return _finish(
        key: key,
        conversationId: conversationId,
        toolCallId: toolCallId,
        name: name,
        args: args,
        isWrite: false,
        status: 'error',
        result: {
          'error': 'unknown_tool',
          'message': 'No tool named "$name" exists.',
        },
        isError: true,
        existing: existing,
      );
    }

    final effectiveArgs = editedArgs ?? args;
    final errors = validator.validate(spec.inputSchema, effectiveArgs);
    if (errors.isNotEmpty) {
      return _finish(
        key: key,
        conversationId: conversationId,
        toolCallId: toolCallId,
        name: name,
        args: effectiveArgs,
        isWrite: spec.isWrite,
        status: 'error',
        result: {
          'error': 'invalid_arguments',
          'details': errors.take(10).toList(),
        },
        isError: true,
        existing: existing,
      );
    }

    if (!await hasConsent(spec.consent)) {
      // Not audited as final: once the user grants consent the same call is
      // executed normally.
      return ToolOutcome._(
        kind: ToolOutcomeKind.consentRequired,
        toolName: name,
        toolCallId: toolCallId,
        args: effectiveArgs,
        consent: spec.consent,
        result: consentRequiredResult(spec.consent),
      );
    }

    if (spec.isWrite && !confirmed) {
      if (existing == null) {
        await db
            .into(db.aiToolActions)
            .insert(
              AiToolActionsCompanion.insert(
                id: newId(),
                conversationId: Value(conversationId),
                toolName: name,
                argsJson: jsonEncode(effectiveArgs),
                status: 'pending_confirmation',
                isWrite: const Value(true),
                idempotencyKey: key,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
      return ToolOutcome._(
        kind: ToolOutcomeKind.pendingConfirmation,
        toolName: name,
        toolCallId: toolCallId,
        args: effectiveArgs,
      );
    }

    Map<String, Object?> result;
    var isError = false;
    try {
      result = await spec
          .handler(contextFor(conversationId, toolCallId), effectiveArgs)
          .timeout(timeout);
    } catch (e) {
      isError = true;
      result = {
        'error': e is TimeoutException ? 'timeout' : 'tool_failed',
        'message': safeErrorMessage(e),
      };
    }
    return _finish(
      key: key,
      conversationId: conversationId,
      toolCallId: toolCallId,
      name: name,
      args: effectiveArgs,
      isWrite: spec.isWrite,
      status: isError ? 'error' : (spec.isWrite ? 'confirmed' : 'ok'),
      result: result,
      isError: isError,
      existing: existing,
    );
  }

  /// Records that the user rejected a pending write.
  Future<ToolOutcome> reject({
    required String conversationId,
    required String toolCallId,
    required String name,
    required Map<String, Object?> args,
    String reason = 'rejected_by_user',
  }) {
    final key = keyFor(conversationId, toolCallId);
    return _serialized(
      key,
      () => _reject(
        key: key,
        conversationId: conversationId,
        toolCallId: toolCallId,
        name: name,
        args: args,
        reason: reason,
      ),
    );
  }

  Future<ToolOutcome> _reject({
    required String key,
    required String conversationId,
    required String toolCallId,
    required String name,
    required Map<String, Object?> args,
    required String reason,
  }) async {
    final existing = await _audit(key);
    if (existing != null && _finalStatuses.contains(existing.status)) {
      return ToolOutcome._(
        kind: ToolOutcomeKind.result,
        toolName: name,
        toolCallId: toolCallId,
        args: _decodeArgs(existing.argsJson),
        result: _decodeResult(existing.resultSummary),
        isError: existing.status == 'error',
        replayed: true,
      );
    }
    return _finish(
      key: key,
      conversationId: conversationId,
      toolCallId: toolCallId,
      name: name,
      args: args,
      isWrite: tools[name]?.isWrite ?? false,
      status: 'rejected',
      result: {
        'status': reason,
        'message': switch (reason) {
          'consent_declined' =>
            'The user declined to share this data with the AI. Do not '
                'retry; answer without it or explain what is unavailable.',
          'cancelled' =>
            'This step was cancelled or interrupted before it ran. Nothing '
                'was written.',
          _ =>
            'The user did not approve this change. Nothing was written. '
                'Ask what they would like instead.',
        },
      },
      isError: false,
      existing: existing,
    );
  }

  Future<ToolOutcome> _finish({
    required String key,
    required String conversationId,
    required String toolCallId,
    required String name,
    required Map<String, Object?> args,
    required bool isWrite,
    required String status,
    required Map<String, Object?> result,
    required bool isError,
    required AiToolAction? existing,
  }) async {
    final now = DateTime.now().toUtc();
    final resultJson = jsonEncode(result);
    if (existing == null) {
      await db
          .into(db.aiToolActions)
          .insert(
            AiToolActionsCompanion.insert(
              id: newId(),
              conversationId: Value(conversationId),
              toolName: name,
              argsJson: jsonEncode(args),
              resultSummary: Value(resultJson),
              status: status,
              isWrite: Value(isWrite),
              idempotencyKey: key,
              confirmedAt: Value(status == 'confirmed' ? now : null),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    } else {
      await (db.update(
        db.aiToolActions,
      )..where((a) => a.idempotencyKey.equals(key))).write(
        AiToolActionsCompanion(
          argsJson: Value(jsonEncode(args)),
          resultSummary: Value(resultJson),
          status: Value(status),
          confirmedAt: Value(status == 'confirmed' ? now : null),
        ),
      );
    }
    return ToolOutcome._(
      kind: ToolOutcomeKind.result,
      toolName: name,
      toolCallId: toolCallId,
      args: args,
      result: result,
      isError: isError,
    );
  }

  static Map<String, Object?> consentRequiredResult(ToolConsent consent) => {
    'status': 'consent_required',
    'consent': consent.name,
    'message':
        'The user has not allowed ${consent == ToolConsent.journal ? 'journal entries' : 'health data'} '
        'to be shared with the AI. Tell them they can allow it in the consent '
        'card or in AI settings; do not guess the data.',
  };

  /// Redacted, single-line error text that is safe to show and to send.
  static String safeErrorMessage(Object e) {
    var s = e is ArgumentError
        ? (e.message?.toString() ?? 'Invalid argument')
        : e.toString();
    s = s.split('\n').first;
    if (s.length > 300) s = '${s.substring(0, 300)}…';
    return redactSecrets(s);
  }

  static Map<String, Object?> _decodeArgs(String json) {
    try {
      return (jsonDecode(json) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  static Map<String, Object?> _decodeResult(String? json) {
    if (json == null) return const {};
    try {
      return (jsonDecode(json) as Map).cast<String, Object?>();
    } catch (_) {
      return {'summary': json};
    }
  }
}
