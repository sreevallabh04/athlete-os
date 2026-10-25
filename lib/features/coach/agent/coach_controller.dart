import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../data/ai_backend.dart';
import '../data/ai_preferences.dart';
import '../data/ai_text_service.dart';
import '../data/coach_auth.dart';
import '../data/coach_repository.dart';
import '../tools/tool_executor.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_spec.dart';
import 'briefing.dart';
import 'system_prompt.dart';
import 'tool_router.dart';

/// Maximum model rounds that may request tools within one user turn.
const maxToolRounds = 6;

/// Overall wall-clock budget for one user turn (excluding time the user
/// spends on confirmation/consent cards).
const turnTimeout = Duration(minutes: 3);

/// Messages of history sent per request (newest kept).
const maxHistoryMessages = 40;

/// History budget per request (UTF-8 chars of the wire messages). Together
/// with tool routing this keeps a typical request under ~6 K tokens so
/// Groq's free tier (8 K tokens/minute) can carry the fallback.
const historyCharBudget = 12000;

/// Client-side ceiling on top of the server deadline (at most 45 s): the
/// turn fails with a retryable "timeout" instead of hanging.
Duration clientTimeoutFor(int timeoutMs) =>
    Duration(milliseconds: (timeoutMs < 45000 ? timeoutMs : 45000) + 15000);

/// Local-only conversation rows (briefings). Never sent to a model.
const localRole = 'briefing';

// ---------------------------------------------------------------------------
// Display model
// ---------------------------------------------------------------------------

sealed class ChatEntry {
  const ChatEntry();
}

class UserTextEntry extends ChatEntry {
  const UserTextEntry(this.text);
  final String text;
}

class AssistantTextEntry extends ChatEntry {
  const AssistantTextEntry(this.text, {this.sources = const [], this.model});
  final String text;

  /// Provenance sources of the tool results this answer was based on.
  final List<String> sources;
  final String? model;
}

/// A deterministic briefing (or evening review) rendered locally; optionally
/// rephrased by AI. Stored with role [localRole], never sent to a model.
class BriefingEntry extends ChatEntry {
  const BriefingEntry(
    this.text, {
    this.mode = 'morning',
    this.polished = false,
  });
  final String text;

  /// morning | evening
  final String mode;
  final bool polished;
}

enum ToolChipStatus { running, ok, error, pending, rejected, consent }

class ToolChipEntry extends ChatEntry {
  const ToolChipEntry({
    required this.toolCallId,
    required this.toolName,
    required this.label,
    required this.status,
    this.isWrite = false,
  });
  final String toolCallId;
  final String toolName;
  final String label;
  final ToolChipStatus status;
  final bool isWrite;
}

/// A write confirmation or consent request awaiting the user.
class PendingAction {
  const PendingAction({
    required this.toolCallId,
    required this.toolName,
    required this.args,
    required this.title,
    required this.summary,
    this.consent,
  });

  final String toolCallId;
  final String toolName;
  final Map<String, Object?> args;
  final String title;
  final List<String> summary;

  /// Non-null when this is a consent request rather than a write.
  final ToolConsent? consent;
  bool get isConsent => consent != null;
}

/// What the agent is doing right now (drives the orb and subsystem chips).
enum CoachPhase {
  idle,

  /// Waiting for the model (optimistic "Consulting" UI).
  consulting,

  /// Running local tools.
  tools,

  /// Compiling a deterministic briefing.
  briefing,
}

class CoachState {
  const CoachState({
    this.conversationId,
    this.entries = const [],
    this.busy = false,
    this.statusText,
    this.error,
    this.pending,
    this.notice,
    this.phase = CoachPhase.idle,
    this.phaseSince,
    this.lastProvider,
    this.lastModel,
    this.fallbackUsed = false,
    this.lastLatency,
    this.lastRequest,
    this.voiceTurn = false,
    this.replySerial = 0,
  });

  final String? conversationId;
  final List<ChatEntry> entries;
  final bool busy;
  final String? statusText;
  final AiBackendException? error;
  final PendingAction? pending;
  final String? notice;
  final CoachPhase phase;
  final DateTime? phaseSince;

  /// Provider/model of the latest model response (null until one arrives).
  final String? lastProvider;
  final String? lastModel;

  /// True when the latest response came from a fallback provider.
  final bool fallbackUsed;
  final Duration? lastLatency;

  /// Estimated size of the latest request (tool-routing telemetry).
  final RequestSize? lastRequest;

  /// The current turn was started by voice (its reply is spoken).
  final bool voiceTurn;

  /// Increments whenever a final answer or briefing lands, so the UI can
  /// speak/announce it exactly once.
  final int replySerial;

  bool get canRetry => error != null && error!.retryable;

  CoachState copyWith({
    String? Function()? conversationId,
    List<ChatEntry>? entries,
    bool? busy,
    String? Function()? statusText,
    AiBackendException? Function()? error,
    PendingAction? Function()? pending,
    String? Function()? notice,
    CoachPhase? phase,
    DateTime? phaseSince,
    String? lastProvider,
    String? lastModel,
    bool? fallbackUsed,
    Duration? lastLatency,
    RequestSize? lastRequest,
    bool? voiceTurn,
    int? replySerial,
  }) => CoachState(
    conversationId: conversationId != null
        ? conversationId()
        : this.conversationId,
    entries: entries ?? this.entries,
    busy: busy ?? this.busy,
    statusText: statusText != null ? statusText() : this.statusText,
    error: error != null ? error() : this.error,
    pending: pending != null ? pending() : this.pending,
    notice: notice != null ? notice() : this.notice,
    phase: phase ?? this.phase,
    phaseSince: phaseSince ?? this.phaseSince,
    lastProvider: lastProvider ?? this.lastProvider,
    lastModel: lastModel ?? this.lastModel,
    fallbackUsed: fallbackUsed ?? this.fallbackUsed,
    lastLatency: lastLatency ?? this.lastLatency,
    lastRequest: lastRequest ?? this.lastRequest,
    voiceTurn: voiceTurn ?? this.voiceTurn,
    replySerial: replySerial ?? this.replySerial,
  );
}

class _Batch {
  _Batch(this.calls);
  final List<Map<String, Object?>> calls;
  final List<Map<String, Object?>> results = [];
  int index = 0;
  bool get done => index >= calls.length;
  Map<String, Object?> get current => calls[index];
}

// ---------------------------------------------------------------------------
// Wire helpers (pure, unit-tested)
// ---------------------------------------------------------------------------

List<Map<String, Object?>> decodeBlocks(String json) {
  try {
    return (jsonDecode(json) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Converts persisted messages to the normalised wire format: tool results
/// become user turns, consecutive same-role turns are merged, history is
/// trimmed to [maxMessages] without starting on an orphaned tool result.
///
/// Results of tools named in [withheldTools] (their consent is off now, e.g.
/// revoked after an earlier turn) are replaced by [withheldToolResult], so
/// data shared under a consent is not re-sent once that consent is gone.
List<Map<String, Object?>> toWireMessages(
  List<AiMessage> rows, {
  int maxMessages = maxHistoryMessages,
  int maxChars = 150000,
  bool compactOldToolResults = false,
  Set<String> withheldTools = const {},
}) {
  final out = <Map<String, Object?>>[];
  // Results of earlier turns were already used by the model; big ones are
  // replaced with a stub (it can call the tool again for fresh numbers).
  var lastUserText = -1;
  if (compactOldToolResults) {
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i].role == 'user' &&
          decodeBlocks(rows[i].contentJson).any((b) => b['type'] == 'text')) {
        lastUserText = i;
        break;
      }
    }
  }
  for (var ri = 0; ri < rows.length; ri++) {
    final r = rows[ri];
    if (r.role != 'user' && r.role != 'assistant' && r.role != 'tool') {
      continue; // local-only rows (briefings) never reach a model
    }
    var blocks = decodeBlocks(r.contentJson);
    if (compactOldToolResults && ri < lastUserText && r.role == 'tool') {
      blocks = [
        for (final b in blocks)
          if (b['type'] == 'tool_result' &&
              (b['content'] as String? ?? '').length > 400)
            {...b, 'content': trimmedToolResult}
          else
            b,
      ];
    }
    if (withheldTools.isNotEmpty && r.role == 'tool') {
      blocks = [
        for (final b in blocks)
          if (b['type'] == 'tool_result' &&
              withheldTools.contains(b['name']) &&
              !_isDataFreeResult(b['content']))
            {...b, 'content': withheldToolResult, 'is_error': false}
          else
            b,
      ];
    }
    if (blocks.isEmpty) continue;
    final role = r.role == 'assistant' ? 'assistant' : 'user';
    if (out.isNotEmpty && out.last['role'] == role) {
      final all = [
        ...(out.last['content'] as List).cast<Map<String, Object?>>(),
        ...blocks,
      ];
      // tool_result blocks must lead a user turn (stable partition).
      final merged = role == 'user'
          ? [
              ...all.where((b) => b['type'] == 'tool_result'),
              ...all.where((b) => b['type'] != 'tool_result'),
            ]
          : all;
      out[out.length - 1] = {'role': role, 'content': merged};
    } else {
      out.add({'role': role, 'content': blocks});
    }
  }
  if (out.isEmpty) return out;
  int nextUser(int s) {
    while (s < out.length && out[s]['role'] != 'user') {
      s++;
    }
    return s;
  }

  var start = nextUser(out.length > maxMessages ? out.length - maxMessages : 0);
  // Keep the request body well under the backend's 256 KB limit.
  while (start < out.length - 1 &&
      jsonEncode(out.sublist(start)).length > maxChars) {
    start = nextUser(start + 1);
  }
  final kept = start >= out.length ? [out.last] : out.sublist(start);

  // Drop tool results whose tool call was trimmed away.
  final callIds = {
    for (final m in kept)
      for (final b in (m['content'] as List).cast<Map<String, Object?>>())
        if (b['type'] == 'tool_call') b['id'],
  };
  final cleaned = <Map<String, Object?>>[];
  for (final m in kept) {
    final content = (m['content'] as List)
        .cast<Map<String, Object?>>()
        .where(
          (b) =>
              b['type'] != 'tool_result' || callIds.contains(b['tool_call_id']),
        )
        .toList();
    if (content.isEmpty) continue;
    if (cleaned.isEmpty && m['role'] != 'user') continue;
    cleaned.add({'role': m['role'], 'content': content});
  }
  return cleaned;
}

/// Stub that replaces large tool results of earlier turns on the wire.
const trimmedToolResult =
    '{"note":"Earlier result trimmed to save tokens; call the tool again '
    'if you need these numbers."}';

/// Stub for results whose consent is off now (see [toWireMessages]).
const withheldToolResult =
    '{"status":"withheld","note":"The user no longer allows this data to be '
    'shared with the AI; it was removed from the history. Do not use or '
    'guess it."}';

/// Status-only results (consent prompts, rejections, cancellations) carry no
/// user data and stay as they are.
bool _isDataFreeResult(Object? content) {
  if (content is! String) return true;
  try {
    final json = jsonDecode(content);
    return json is Map &&
        const {
          'consent_required',
          'consent_declined',
          'rejected_by_user',
          'cancelled',
          'withheld',
        }.contains(json['status']);
  } catch (_) {
    return false;
  }
}

/// Model-issued tool-call ids are the idempotency keys of tool side effects
/// (`conversationId:toolCallId`), so they must be unique per conversation.
/// Providers that do not issue ids get synthesised ones on the server
/// (`gemini-0-log_water`), which repeat across turns: a second "log 250 ml"
/// would then replay the first call's stored result instead of asking for
/// approval and writing. Ids already used in [taken] (or repeated within
/// [content]) are given a deterministic suffix; matching is by id only, so the
/// rest of each block (provider metadata) is untouched.
List<Map<String, Object?>> withUniqueToolCallIds(
  List<Map<String, Object?>> content,
  Set<String> taken,
) {
  final used = {...taken};
  return [
    for (final b in content)
      if (b['type'] == 'tool_call' && b['id'] is String)
        () {
          final id = b['id'] as String;
          var unique = id;
          for (var n = 2; used.contains(unique); n++) {
            unique = '${id}_$n';
          }
          used.add(unique);
          return unique == id ? b : {...b, 'id': unique};
        }()
      else
        b,
  ];
}

/// Every tool-call id already present in a conversation.
Set<String> toolCallIdsIn(List<AiMessage> rows) => {
  for (final r in rows)
    if (r.role == 'assistant')
      for (final b in decodeBlocks(r.contentJson))
        if (b['type'] == 'tool_call' && b['id'] is String) b['id'] as String,
};

/// Tool names called in [rows], newest first, without duplicates.
List<String> recentToolNames(List<AiMessage> rows, {int max = 4}) {
  final out = <String>[];
  for (final r in rows.reversed) {
    if (r.role != 'assistant') continue;
    for (final b in decodeBlocks(r.contentJson).reversed) {
      final n = b['name'];
      if (b['type'] == 'tool_call' && n is String && !out.contains(n)) {
        out.add(n);
        if (out.length >= max) return out;
      }
    }
  }
  return out;
}

/// Builds the display list from persisted messages.
List<ChatEntry> buildEntries(
  List<AiMessage> rows,
  DateTime now, {
  PendingAction? pending,
  Set<String> runningIds = const {},
}) {
  final results = <String, Map<String, Object?>>{};
  for (final r in rows.where((r) => r.role == 'tool')) {
    for (final b in decodeBlocks(r.contentJson)) {
      final id = b['tool_call_id'];
      if (id is String) results[id] = b;
    }
  }
  final entries = <ChatEntry>[];
  var sources = <String>{};
  for (final r in rows) {
    final blocks = decodeBlocks(r.contentJson);
    switch (r.role) {
      case localRole:
        for (final b in blocks) {
          final text = (b['text'] as String? ?? '').trim();
          if (text.isEmpty) continue;
          entries.add(
            b['from'] == 'user'
                ? UserTextEntry(text)
                : BriefingEntry(
                    text,
                    mode: b['mode'] as String? ?? 'morning',
                    polished: b['polished'] == true,
                  ),
          );
        }
      case 'user':
        sources = <String>{};
        final text = blocks
            .where((b) => b['type'] == 'text')
            .map((b) => b['text'])
            .join('\n');
        if (text.trim().isNotEmpty) entries.add(UserTextEntry(text));
      case 'tool':
        for (final b in blocks) {
          final content = b['content'];
          if (content is! String) continue;
          try {
            final json = jsonDecode(content);
            final prov = json is Map ? json['provenance'] : null;
            final s = prov is Map ? prov['sources'] : null;
            if (s is List) {
              sources.addAll(
                s.map((e) => e.toString()).where((e) => e != 'none'),
              );
            }
          } catch (_) {}
        }
      case 'assistant':
        for (final b in blocks) {
          if (b['type'] == 'text' &&
              (b['text'] as String? ?? '').trim() != '') {
            entries.add(
              AssistantTextEntry(
                (b['text'] as String).trim(),
                sources: sources.toList()..sort(),
                model: r.model,
              ),
            );
          } else if (b['type'] == 'tool_call') {
            final id = b['id'] as String? ?? '';
            final name = b['name'] as String? ?? '';
            final args =
                (b['arguments'] as Map?)?.cast<String, Object?>() ?? {};
            final spec = toolByName(name);
            final res = results[id];
            ToolChipStatus status;
            if (res != null) {
              final content = res['content'] as String? ?? '';
              status = res['is_error'] == true
                  ? ToolChipStatus.error
                  : content.contains('"consent_required"')
                  ? ToolChipStatus.consent
                  : content.contains('"rejected_by_user"') ||
                        content.contains('"consent_declined"') ||
                        content.contains('"cancelled"')
                  ? ToolChipStatus.rejected
                  : ToolChipStatus.ok;
            } else if (pending?.toolCallId == id) {
              status = pending!.isConsent
                  ? ToolChipStatus.consent
                  : ToolChipStatus.pending;
            } else {
              status = runningIds.contains(id)
                  ? ToolChipStatus.running
                  : ToolChipStatus.pending;
            }
            String label;
            try {
              label = spec?.chipLabel(args, now) ?? name;
            } catch (_) {
              label = name;
            }
            entries.add(
              ToolChipEntry(
                toolCallId: id,
                toolName: name,
                label: label,
                status: status,
                isWrite: spec?.isWrite ?? false,
              ),
            );
          }
        }
    }
  }
  return entries;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class CoachController extends Notifier<CoachState> {
  _Batch? _batch;
  String? _requestId;
  int _generation = 0;
  int _rounds = 0;
  DateTime? _deadline;
  bool _reportedConnected = false;

  /// Tools routed for the current turn (null = not routed yet).
  ToolRoute? _route;

  /// The model asked for a tool it was not given: send the full catalogue
  /// for the rest of this turn.
  bool _widened = false;

  /// One-shot provider override for a "fast retry" (Groq).
  String? _primaryOverride;

  @override
  CoachState build() => const CoachState();

  CoachRepository get _repo => ref.read(coachRepositoryProvider);
  ToolExecutor get _executor => ref.read(toolExecutorProvider);
  Clock get _clock => ref.read(clockProvider);

  /// Fresh state that keeps the link telemetry (provider, latency).
  CoachState _blank({String? conversationId, List<ChatEntry>? entries}) =>
      CoachState(
        conversationId: conversationId,
        entries: entries ?? const [],
        lastProvider: state.lastProvider,
        lastModel: state.lastModel,
        fallbackUsed: state.fallbackUsed,
        lastLatency: state.lastLatency,
        lastRequest: state.lastRequest,
        replySerial: state.replySerial,
      );

  void _resetTurn() {
    _batch = null;
    _requestId = null;
    _route = null;
    _widened = false;
    _primaryOverride = null;
  }

  /// Starts a fresh chat (the conversation row is created on first send).
  void newConversation() {
    _generation++;
    _resetTurn();
    state = _blank();
  }

  Future<void> openConversation(String id) async {
    _generation++;
    _resetTurn();
    final rows = await _repo.messages(id);
    state = _blank(
      conversationId: id,
      entries: buildEntries(rows, _clock.now()),
    );
    await _closeDanglingToolCalls(id, rows);
  }

  /// If the app stopped mid-turn, answer unanswered tool calls so the
  /// history stays valid. Finished calls replay their stored result; pending
  /// writes are recorded as interrupted (nothing is written).
  Future<void> _closeDanglingToolCalls(String id, List<AiMessage> rows) async {
    // Local briefing rows never reach a model; look past them.
    final wire = rows.where((r) => r.role != localRole);
    if (wire.isEmpty || wire.last.role != 'assistant') return;
    final calls = decodeBlocks(wire.last.contentJson)
        .where((b) => b['type'] == 'tool_call')
        .toList();
    if (calls.isEmpty) return;
    final results = <Map<String, Object?>>[];
    for (final c in calls) {
      final outcome = await _executor.reject(
        conversationId: id,
        toolCallId: c['id'] as String,
        name: c['name'] as String,
        args: (c['arguments'] as Map?)?.cast<String, Object?>() ?? {},
        reason: 'cancelled',
      );
      results.add(outcome.toResultBlock());
    }
    await _repo.addMessage(id, 'tool', results);
    await _reload();
  }

  Future<void> _reload({Set<String> running = const {}}) async {
    final id = state.conversationId;
    if (id == null) return;
    final rows = await _repo.messages(id);
    if (!ref.mounted) return;
    state = state.copyWith(
      entries: buildEntries(
        rows,
        _clock.now(),
        pending: state.pending,
        runningIds: running,
      ),
    );
  }

  void _setPhase(CoachPhase phase, {String? status}) {
    state = state.copyWith(
      phase: phase,
      phaseSince: _clock.now(),
      busy: phase != CoachPhase.idle,
      statusText: () => status,
    );
  }

  Future<String> _ensureConversation(String title) async {
    var id = state.conversationId;
    if (id == null) {
      id = await _repo.createConversation(
        title: title.length > 60 ? '${title.substring(0, 60)}…' : title,
      );
      state = state.copyWith(conversationId: () => id);
    }
    return id;
  }

  /// Runs one step of the agent loop. Any unexpected failure (database,
  /// tool plumbing) ends the turn with a retryable error card instead of
  /// leaving the coach "busy" forever.
  Future<void> _guarded(int gen, Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      _fail(AiBackendException('internal', ToolExecutor.safeErrorMessage(e)));
    }
  }

  /// Sends a user message and runs the agent loop. [viaVoice] marks the
  /// turn as spoken so the UI can read the answer aloud.
  ///
  /// Returns false when the message was not accepted (empty, a turn or card
  /// is in progress, or the backend is unavailable), so the caller can keep
  /// the text instead of losing it.
  Future<bool> send(String text, {bool viaVoice = false}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.busy || state.pending != null) return false;
    final gen = _generation;
    var backend = ref.read(aiBackendClientProvider);
    if (backend.state == AiBackendState.signedOut) {
      // The automatic anonymous sign-in runs once at launch and gives up
      // quietly when offline; try again now that the user wants the coach.
      _setPhase(CoachPhase.consulting, status: 'Signing in…');
      await ensureAnonymousSession(
        ref.read(coachAuthProvider),
        ref.read(settingsRepositoryProvider),
      );
      if (gen != _generation || !ref.mounted) return false;
      backend = ref.read(aiBackendClientProvider);
      state = state.copyWith(
        busy: false,
        phase: CoachPhase.idle,
        statusText: () => null,
      );
    }
    if (backend.state != AiBackendState.ready) {
      state = state.copyWith(
        error: () => backend.state == AiBackendState.signedOut
            ? const AiBackendException(
                'unauthorized',
                "Couldn't sign in to the AI backend. Check your connection "
                    'and try again, or sign in from AI settings.',
              )
            : const AiBackendException(
                'awaiting_credentials',
                'The AI backend is not set up yet. Open AI settings to '
                    'connect it.',
              ),
      );
      return false;
    }
    final message = trimmed.length > 4000
        ? trimmed.substring(0, 4000)
        : trimmed;
    // Optimistic: the orb starts thinking before any IO.
    _resetTurn();
    state = state.copyWith(
      error: () => null,
      notice: () => null,
      voiceTurn: viaVoice,
    );
    _setPhase(CoachPhase.consulting, status: 'Consulting…');
    await _guarded(gen, () async {
      final id = await _ensureConversation(message);
      // A turn that failed mid-batch (and was not retried) may have left
      // tool calls without results; close them so the history stays valid.
      await _closeDanglingToolCalls(id, await _repo.messages(id));
      await _repo.addMessage(id, 'user', [
        {'type': 'text', 'text': message},
      ]);
      final rows = await _repo.messages(id);
      _route = routeTools(message, recentTools: recentToolNames(rows));
      _rounds = 0;
      _deadline = _clock.now().add(turnTimeout);
      await _reload();
      await _callModel(gen);
    });
    return true;
  }

  /// Retries the failed model call with the SAME request id, so the server
  /// can return its cached response rather than charging twice.
  ///
  /// With [fast], the call is re-sent (new request id) with Groq as the
  /// primary provider — the routed request is small enough for its tier.
  Future<void> retry({bool fast = false}) async {
    if (state.busy || state.error == null || state.conversationId == null) {
      return;
    }
    _deadline = _clock.now().add(turnTimeout);
    if (fast) {
      _primaryOverride = 'groq';
      _requestId = null;
    }
    state = state.copyWith(error: () => null);
    final gen = _generation;
    await _guarded(gen, () async {
      if (_batch != null) {
        await _processBatch(gen);
      } else {
        await _callModel(gen);
      }
    });
  }

  /// Stops the current turn. Unanswered tool calls are closed as cancelled
  /// (pending writes are not executed).
  Future<void> cancel() async {
    _generation++;
    final id = state.conversationId;
    final batch = _batch;
    _batch = null;
    _requestId = null;
    if (id != null && batch != null) {
      try {
        while (!batch.done) {
          final c = batch.current;
          final outcome = await _executor.reject(
            conversationId: id,
            toolCallId: c['id'] as String,
            name: c['name'] as String,
            args: (c['arguments'] as Map?)?.cast<String, Object?>() ?? {},
            reason: 'cancelled',
          );
          batch.results.add(outcome.toResultBlock());
          batch.index++;
        }
        await _repo.addMessage(id, 'tool', batch.results);
      } catch (_) {
        // Stopping must always succeed; unanswered calls are closed when the
        // conversation is next opened.
      }
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      busy: false,
      phase: CoachPhase.idle,
      statusText: () => null,
      pending: () => null,
      notice: () => 'Stopped.',
    );
    await _reload();
  }

  List<ToolSpec> get _turnTools =>
      _widened || _route == null ? coachTools : _route!.specs;

  Future<void> _callModel(int gen) async {
    final id = state.conversationId!;
    final backend = ref.read(aiBackendClientProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final db = ref.read(databaseProvider);
    _requestId ??= newId();
    _setPhase(CoachPhase.consulting, status: 'Consulting…');
    final started = DateTime.now();
    AiChatResponse resp;
    try {
      var prefs = await ref.read(aiPreferencesRepositoryProvider).load();
      if (_primaryOverride != null) {
        prefs = prefs.copyWith(
          primaryProvider: () => _primaryOverride,
          model: () => null,
        );
      }
      final inputs = await loadSystemPromptInputs(db, settings, _clock.now());
      final rows = await _repo.messages(id);
      final system = buildSystemPrompt(inputs);
      final messages = toWireMessages(
        rows,
        maxChars: historyCharBudget,
        compactOldToolResults: true,
        withheldTools: {
          for (final t in coachTools)
            if ((t.consent == ToolConsent.health && !inputs.healthConsent) ||
                (t.consent == ToolConsent.journal && !inputs.journalConsent))
              t.name,
        },
      );
      final tools = [for (final t in _turnTools) t.toWire()];
      state = state.copyWith(
        lastRequest: RequestSize.of(
          system: system,
          tools: tools,
          messages: messages,
        ),
      );
      resp = await backend
          .chat(
            AiChatRequest(
              requestId: _requestId!,
              conversationId: id,
              system: system,
              messages: messages,
              tools: tools,
              preferences: prefs,
            ),
          )
          .timeout(clientTimeoutFor(prefs.timeoutMs));
    } on AiBackendException catch (e) {
      if (gen != _generation || !ref.mounted) return;
      _fail(e);
      return;
    } on TimeoutException {
      if (gen != _generation || !ref.mounted) return;
      _fail(
        const AiBackendException(
          'timeout',
          'The AI link timed out. Retry, or switch to the fast provider.',
        ),
      );
      return;
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      _fail(AiBackendException('internal', ToolExecutor.safeErrorMessage(e)));
      return;
    }
    if (gen != _generation || !ref.mounted) return;
    _requestId = null;
    _markConnected();
    state = state.copyWith(
      lastProvider: resp.provider,
      lastModel: resp.model,
      fallbackUsed: resp.meta['fallback_used'] == true,
      lastLatency: DateTime.now().difference(started),
    );
    // Tool-call ids key tool side effects; make them unique in this
    // conversation before they are stored (see [withUniqueToolCallIds]).
    final content = withUniqueToolCallIds(
      resp.content,
      toolCallIdsIn(await _repo.messages(id)),
    );
    await _repo.addMessage(
      id,
      'assistant',
      content,
      provider: resp.provider,
      model: resp.model,
      inputTokens: resp.inputTokens,
      outputTokens: resp.outputTokens,
    );
    final calls = [
      for (final b in content)
        if (b['type'] == 'tool_call') b,
    ];
    if (calls.isEmpty) {
      state = state.copyWith(
        busy: false,
        phase: CoachPhase.idle,
        statusText: () => null,
        notice: () => switch (resp.stopReason) {
          'max_tokens' => 'The answer was cut off (max tokens reached).',
          'refusal' => 'The AI declined to answer this request.',
          _ => null,
        },
      );
      _primaryOverride = null;
      await _reload();
      // Announce only once the answer is in `entries` (auto-speak reads it).
      if (ref.mounted) {
        state = state.copyWith(replySerial: state.replySerial + 1);
      }
      return;
    }
    // Asked for a tool outside the routed subset: it still runs (it is
    // registered locally); the rest of the turn gets the full catalogue.
    final sent = {for (final t in _turnTools) t.name};
    if (calls.any((c) => !sent.contains(c['name']))) _widened = true;
    _rounds++;
    final overRounds = _rounds > maxToolRounds;
    final overTime = _deadline != null && _clock.now().isAfter(_deadline!);
    if (overRounds || overTime) {
      await _repo.addMessage(id, 'tool', [
        for (final c in calls)
          {
            'type': 'tool_result',
            'tool_call_id': c['id'],
            'name': c['name'],
            'content': jsonEncode({
              'status': 'cancelled',
              'message': overRounds
                  ? 'Tool round limit reached.'
                  : 'Turn time limit reached.',
            }),
            'is_error': true,
          },
      ]);
      state = state.copyWith(
        busy: false,
        phase: CoachPhase.idle,
        statusText: () => null,
        notice: () => overRounds
            ? 'Stopped after $maxToolRounds tool steps. Ask a narrower '
                  'question or continue.'
            : 'Stopped: this answer took too long. You can ask again.',
      );
      await _reload();
      return;
    }
    _batch = _Batch(calls);
    await _processBatch(gen);
  }

  void _fail(AiBackendException e) {
    state = state.copyWith(
      busy: false,
      phase: CoachPhase.idle,
      statusText: () => null,
      error: () => e,
    );
  }

  Future<void> _processBatch(int gen) async {
    final id = state.conversationId!;
    final batch = _batch;
    if (batch == null) return;
    _setPhase(CoachPhase.tools, status: 'Checking your data…');
    while (!batch.done) {
      final c = batch.current;
      final callId = c['id'] as String;
      final name = c['name'] as String;
      final args = (c['arguments'] as Map?)?.cast<String, Object?>() ?? {};
      await _reload(running: {callId});
      final outcome = await _executor.execute(
        conversationId: id,
        toolCallId: callId,
        name: name,
        args: args,
      );
      if (gen != _generation || !ref.mounted) return;
      switch (outcome.kind) {
        case ToolOutcomeKind.result:
          batch.results.add(outcome.toResultBlock());
          batch.index++;
        case ToolOutcomeKind.pendingConfirmation:
          final spec = toolByName(name);
          List<String> summary;
          try {
            summary = spec?.confirmSummary?.call(outcome.args) ?? const [];
          } catch (_) {
            summary = const [];
          }
          state = state.copyWith(
            busy: false,
            phase: CoachPhase.idle,
            statusText: () => null,
            pending: () => PendingAction(
              toolCallId: callId,
              toolName: name,
              args: outcome.args,
              title: spec?.confirmTitle ?? name,
              summary: summary,
            ),
          );
          await _reload();
          return;
        case ToolOutcomeKind.consentRequired:
          final consent = outcome.consent!;
          state = state.copyWith(
            busy: false,
            phase: CoachPhase.idle,
            statusText: () => null,
            pending: () => PendingAction(
              toolCallId: callId,
              toolName: name,
              args: outcome.args,
              title: consent == ToolConsent.journal
                  ? 'Share journal excerpts with the AI?'
                  : 'Share health data with the AI?',
              summary: [
                consent == ToolConsent.journal
                    ? 'The coach wants to read short excerpts (first 200 '
                          'characters) of your journal entries.'
                    : 'The coach wants to read your logged health and '
                          'fitness data (food, water, steps, training, '
                          'mood, targets) to answer.',
                'Only the minimal results are sent to the AI provider via '
                    'your backend. You can turn this off in AI settings.',
              ],
              consent: consent,
            ),
          );
          await _reload();
          return;
      }
    }
    await _repo.addMessage(id, 'tool', batch.results);
    _batch = null;
    await _reload();
    await _callModel(gen);
  }

  /// Approves the pending write (optionally with user-edited arguments) or
  /// grants the pending consent, then continues the agent loop.
  Future<void> approve({Map<String, Object?>? editedArgs}) async {
    final p = state.pending;
    final batch = _batch;
    final id = state.conversationId;
    if (p == null || batch == null || id == null) return;
    final gen = _generation;
    state = state.copyWith(pending: () => null, busy: true);
    await _guarded(gen, () => _approve(p, batch, id, gen, editedArgs));
  }

  Future<void> _approve(
    PendingAction p,
    _Batch batch,
    String id,
    int gen,
    Map<String, Object?>? editedArgs,
  ) async {
    if (p.isConsent) {
      await ref
          .read(settingsRepositoryProvider)
          .set(
            p.consent == ToolConsent.journal
                ? SettingKeys.aiJournalConsent
                : SettingKeys.aiHealthConsent,
            true,
          );
      // Re-run the same call now that consent exists (writes will still ask
      // for confirmation).
      _deadline = _clock.now().add(turnTimeout);
      await _processBatch(gen);
      return;
    }
    final outcome = await _executor.execute(
      conversationId: id,
      toolCallId: p.toolCallId,
      name: p.toolName,
      args: p.args,
      confirmed: true,
      editedArgs: editedArgs,
    );
    if (gen != _generation || !ref.mounted) return;
    batch.results.add(outcome.toResultBlock());
    batch.index++;
    _deadline = _clock.now().add(turnTimeout);
    await _processBatch(gen);
  }

  /// Rejects the pending write / declines consent; the model is told and
  /// continues without it.
  Future<void> reject() async {
    final p = state.pending;
    final batch = _batch;
    final id = state.conversationId;
    if (p == null || batch == null || id == null) return;
    final gen = _generation;
    state = state.copyWith(pending: () => null, busy: true);
    await _guarded(gen, () async {
      final outcome = await _executor.reject(
        conversationId: id,
        toolCallId: p.toolCallId,
        name: p.toolName,
        args: p.args,
        reason: p.isConsent ? 'consent_declined' : 'rejected_by_user',
      );
      if (gen != _generation || !ref.mounted) return;
      batch.results.add(outcome.toResultBlock());
      batch.index++;
      _deadline = _clock.now().add(turnTimeout);
      await _processBatch(gen);
    });
  }

  // -------------------------------------------------------------------------
  // Briefings
  // -------------------------------------------------------------------------

  /// "Brief me" / "Review my day": a deterministic briefing from local data
  /// (works offline, no AI). When the backend is ready and the user allowed
  /// health data for AI, the text is then rephrased in the persona's voice
  /// by one small, tool-less call; any failure keeps the deterministic text.
  Future<void> brief(BriefingMode mode, {bool viaVoice = false}) async {
    if (state.busy || state.pending != null) return;
    final gen = _generation;
    _resetTurn();
    state = state.copyWith(
      error: () => null,
      notice: () => null,
      voiceTurn: viaVoice,
    );
    _setPhase(CoachPhase.briefing, status: 'Compiling briefing…');
    try {
      await _brief(mode, gen);
    } catch (_) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        busy: false,
        phase: CoachPhase.idle,
        statusText: () => null,
        notice: () => 'The briefing could not be compiled. Try again.',
      );
    }
  }

  Future<void> _brief(BriefingMode mode, int gen) async {
    final id = await _ensureConversation(
      mode == BriefingMode.morning ? 'Morning briefing' : 'Evening review',
    );
    await _repo.addMessage(id, localRole, [
      {'type': 'text', 'from': 'user', 'text': mode.command},
    ]);
    final inputs = await gatherBriefingInputs(ref);
    if (gen != _generation || !ref.mounted) return;
    final text = composeBriefing(mode, inputs);
    final row = await _repo.addMessage(id, localRole, [
      {'type': 'text', 'mode': mode.name, 'text': text},
    ]);
    await _reload();
    final settings = ref.read(settingsRepositoryProvider);
    final consent =
        (await settings.get<bool>(SettingKeys.aiHealthConsent)) ?? false;
    final backend = ref.read(aiBackendClientProvider);
    if (!consent || backend.state != AiBackendState.ready) {
      _finishBriefing();
      return;
    }
    state = state.copyWith(statusText: () => 'Polishing…');
    try {
      final persona = resolvePersona(
        await settings.get<String>(AiSettingKeys.persona),
      );
      // Only health-consented facts are sent; device-only lines (names from
      // other apps' notifications) are appended locally afterwards.
      final split = splitBriefingForAi(mode, inputs);
      final r = await ref
          .read(aiTextServiceProvider)
          .complete(
            system: briefingPolishPrompt(persona),
            user: split.forAi,
            maxTokens: 700,
          )
          .timeout(const Duration(seconds: 25));
      if (gen != _generation || !ref.mounted) return;
      final polished = r.text.trim();
      if (polished.isNotEmpty && !r.truncated) {
        await _repo.updateMessageContent(
          row.id,
          [
            {
              'type': 'text',
              'mode': mode.name,
              'text': split.deviceOnly.isEmpty
                  ? polished
                  : '$polished\n${split.deviceOnly}',
              'polished': true,
              'facts': text,
            },
          ],
          provider: r.provider,
          model: r.model,
        );
        state = state.copyWith(lastProvider: r.provider, lastModel: r.model);
      }
    } catch (_) {
      // Keep the deterministic briefing; it is already on screen.
    }
    if (gen != _generation || !ref.mounted) return;
    await _reload();
    _finishBriefing();
  }

  void _finishBriefing() {
    state = state.copyWith(
      busy: false,
      phase: CoachPhase.idle,
      statusText: () => null,
      replySerial: state.replySerial + 1,
    );
  }

  void dismissNotice() => state = state.copyWith(
    notice: () => null,
    error: () => state.canRetry ? state.error : null,
  );

  void _markConnected() {
    if (_reportedConnected) return;
    _reportedConnected = true;
    unawaited(
      ref
          .read(integrationStatusRepositoryProvider)
          .setStatus(Providers.aiBackend, ConnectionStates.connected)
          .catchError((_) {}),
    );
  }
}

final coachControllerProvider = NotifierProvider<CoachController, CoachState>(
  CoachController.new,
);
