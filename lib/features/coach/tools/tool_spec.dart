import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/water_repository.dart';

/// Which user consent a tool needs before its output may be sent to an AI
/// provider.
enum ToolConsent {
  none,

  /// `SettingKeys.aiHealthConsent` — nutrition, water, steps, training,
  /// mood, profile targets and restrictions.
  health,

  /// `SettingKeys.aiJournalConsent` — journal text.
  journal,
}

/// Everything a tool handler may touch. Handlers read Drift directly and must
/// be deterministic for a given database + clock.
class ToolContext {
  const ToolContext({
    required this.db,
    required this.clock,
    required this.water,
    required this.calendar,
    required this.conversationId,
    required this.toolCallId,
  });

  final AppDatabase db;
  final Clock clock;
  final WaterRepository water;
  final CalendarReader calendar;
  final String conversationId;
  final String toolCallId;

  DateTime get now => clock.now();
  String get today => LocalDates.key(now);

  /// Stable key for rows written by this tool call, so a retried call can
  /// never create a second row (insert-or-ignore on a deterministic id).
  String get idempotencyKey => '$conversationId:$toolCallId';
}

typedef ToolHandler = Future<Map<String, Object?>> Function(
  ToolContext ctx,
  Map<String, Object?> args,
);

/// Declarative description of one agent tool.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.isWrite = false,
    this.consent = ToolConsent.none,
    required this.chipLabel,
    this.confirmTitle,
    this.confirmSummary,
  });

  final String name;
  final String description;

  /// JSON Schema subset understood by [ToolArgsValidator].
  final Map<String, Object?> inputSchema;
  final ToolHandler handler;

  /// Write tools run only after the user approves a confirmation card.
  final bool isWrite;
  final ToolConsent consent;

  /// Short activity-chip text, e.g. "Read nutrition · Oct 25".
  final String Function(Map<String, Object?> args, DateTime now) chipLabel;

  /// Confirmation card title and human-readable summary for write tools.
  final String? confirmTitle;
  final List<String> Function(Map<String, Object?> args)? confirmSummary;

  /// Wire format sent to the backend (provider-neutral).
  Map<String, Object?> toWire() => {
    'name': name,
    'description': description,
    'input_schema': inputSchema,
  };
}
