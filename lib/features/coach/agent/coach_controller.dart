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
import '../data/coach_repository.dart';
import '../tools/tool_executor.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_spec.dart';
import 'system_prompt.dart';

/// Maximum model rounds that may request tools within one user turn.
const maxToolRounds = 6;

/// Overall wall-clock budget for one user turn (excluding time the user
/// spends on confirmation/consent cards).
const turnTimeout = Duration(minutes: 3);

/// Messages of history sent per request (newest kept).
const maxHistoryMessages = 40;

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

class CoachState {
  const CoachState({
    this.conversationId,
    this.entries = const [],
    this.busy = false,
    this.statusText,
    this.error,
    this.pending,
    this.notice,
  });

  final String? conversationId;
  final List<ChatEntry> entries;
  final bool busy;
  final String? statusText;
  final AiBackendException? error;
  final PendingAction? pending;
  final String? notice;

  bool get canRetry => error != null && error!.retryable;

  CoachState copyWith({
    String? Function()? conversationId,
    List<ChatEntry>? entries,
    bool? busy,
    String? Function()? statusText,
    AiBackendException? Function()? error,
    PendingAction? Function()? pending,
    String? Function()? notice,
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
List<Map<String, Object?>> toWireMessages(
  List<AiMessage> rows, {
  int maxMessages = maxHistoryMessages,
  int maxChars = 150000,
}) {
  final out = <Map<String, Object?>>[];
  for (final r in rows) {
    final blocks = decodeBlocks(r.contentJson);
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

  @override
  CoachState build() => const CoachState();

  CoachRepository get _repo => ref.read(coachRepositoryProvider);
  ToolExecutor get _executor => ref.read(toolExecutorProvider);
  Clock get _clock => ref.read(clockProvider);

  /// Starts a fresh chat (the conversation row is created on first send).
  void newConversation() {
    _generation++;
    _batch = null;
    _requestId = null;
    state = const CoachState();
  }

  Future<void> openConversation(String id) async {
    _generation++;
    _batch = null;
    _requestId = null;
    final rows = await _repo.messages(id);
    state = CoachState(
      conversationId: id,
      entries: buildEntries(rows, _clock.now()),
    );
    await _closeDanglingToolCalls(id, rows);
  }

  /// If the app stopped mid-turn, answer unanswered tool calls so the
  /// history stays valid. Finished calls replay their stored result; pending
  /// writes are recorded as interrupted (nothing is written).
  Future<void> _closeDanglingToolCalls(String id, List<AiMessage> rows) async {
    if (rows.isEmpty || rows.last.role != 'assistant') return;
    final calls = decodeBlocks(rows.last.contentJson)
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

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.busy || state.pending != null) return;
    final backend = ref.read(aiBackendClientProvider);
    if (backend.state != AiBackendState.ready) {
      state = state.copyWith(
        error: () => const AiBackendException(
          'awaiting_credentials',
          'The AI backend is not set up yet. Open AI settings to connect it.',
        ),
      );
      return;
    }
    final message = trimmed.length > 4000
        ? trimmed.substring(0, 4000)
        : trimmed;
    var id = state.conversationId;
    if (id == null) {
      id = await _repo.createConversation(
        title: message.length > 60 ? '${message.substring(0, 60)}…' : message,
      );
      state = state.copyWith(conversationId: () => id);
    }
    await _repo.addMessage(id, 'user', [
      {'type': 'text', 'text': message},
    ]);
    _rounds = 0;
    _requestId = null;
    _deadline = _clock.now().add(turnTimeout);
    state = state.copyWith(error: () => null, notice: () => null);
    await _reload();
    await _callModel(_generation);
  }

  /// Retries the failed model call with the SAME request id, so the server
  /// can return its cached response rather than charging twice.
  Future<void> retry() async {
    if (state.busy || state.error == null || state.conversationId == null) {
      return;
    }
    _deadline = _clock.now().add(turnTimeout);
    state = state.copyWith(error: () => null);
    if (_batch != null) {
      await _processBatch(_generation);
    } else {
      await _callModel(_generation);
    }
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
    }
    state = state.copyWith(
      busy: false,
      statusText: () => null,
      pending: () => null,
      notice: () => 'Stopped.',
    );
    await _reload();
  }

  Future<void> _callModel(int gen) async {
    final id = state.conversationId!;
    final backend = ref.read(aiBackendClientProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final db = ref.read(databaseProvider);
    _requestId ??= newId();
    state = state.copyWith(busy: true, statusText: () => 'Thinking…');
    AiChatResponse resp;
    try {
      final prefs = await ref.read(aiPreferencesRepositoryProvider).load();
      final inputs = await loadSystemPromptInputs(db, settings, _clock.now());
      final rows = await _repo.messages(id);
      resp = await backend.chat(
        AiChatRequest(
          requestId: _requestId!,
          conversationId: id,
          system: buildSystemPrompt(inputs),
          messages: toWireMessages(rows),
          tools: [for (final t in coachTools) t.toWire()],
          preferences: prefs,
        ),
      );
    } on AiBackendException catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        busy: false,
        statusText: () => null,
        error: () => e,
      );
      return;
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        busy: false,
        statusText: () => null,
        error: () =>
            AiBackendException('internal', ToolExecutor.safeErrorMessage(e)),
      );
      return;
    }
    if (gen != _generation || !ref.mounted) return;
    _requestId = null;
    _markConnected();
    await _repo.addMessage(
      id,
      'assistant',
      resp.content,
      provider: resp.provider,
      model: resp.model,
      inputTokens: resp.inputTokens,
      outputTokens: resp.outputTokens,
    );
    final calls = resp.toolCalls;
    if (calls.isEmpty) {
      state = state.copyWith(
        busy: false,
        statusText: () => null,
        notice: () => switch (resp.stopReason) {
          'max_tokens' => 'The answer was cut off (max tokens reached).',
          'refusal' => 'The AI declined to answer this request.',
          _ => null,
        },
      );
      await _reload();
      return;
    }
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

  Future<void> _processBatch(int gen) async {
    final id = state.conversationId!;
    final batch = _batch;
    if (batch == null) return;
    state = state.copyWith(busy: true, statusText: () => 'Checking your data…');
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
