import 'dart:async';

import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/tools/tool_executor.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:athlete_os/features/coach/tools/tool_spec.dart';
import 'package:drift/drift.dart';

/// 09:00 local on Sunday 2026-10-25.
final testNow = DateTime(2026, 10, 25, 9);
const testToday = '2026-10-25';

ToolContext toolContext(
  AppDatabase db, {
  DateTime? now,
  CalendarReader calendar = const DisconnectedCalendarReader(),
  String conversationId = 'conv-1',
  String toolCallId = 'call-1',
}) {
  final clock = FixedClock(now ?? testNow);
  return ToolContext(
    db: db,
    clock: clock,
    water: WaterRepository(db, clock),
    calendar: calendar,
    conversationId: conversationId,
    toolCallId: toolCallId,
  );
}

ToolExecutor executorFor(
  AppDatabase db, {
  List<ToolSpec>? tools,
  DateTime? now,
}) => ToolExecutor(
  db: db,
  settings: SettingsRepository(db),
  tools: tools ?? coachTools,
  contextFor: (c, t) =>
      toolContext(db, now: now, conversationId: c, toolCallId: t),
);

Future<void> grantHealthConsent(AppDatabase db, [bool value = true]) =>
    SettingsRepository(db).set(SettingKeys.aiHealthConsent, value);

Future<void> addFood(
  AppDatabase db, {
  required String id,
  required String date,
  required double kcal,
  double protein = 0,
  String name = 'Food',
  String source = 'manual',
  String verification = 'user_entered',
  bool deleted = false,
}) => db
    .into(db.foodLogEntries)
    .insert(
      FoodLogEntriesCompanion.insert(
        id: id,
        name: name,
        mealType: 'lunch',
        calories: kcal,
        proteinG: Value(protein),
        source: source,
        verification: verification,
        loggedAt: DateTime.utc(2026, 10, 25, 6),
        localDate: date,
        tzName: 'UTC',
        deletedAt: Value(deleted ? DateTime.utc(2026, 10, 25, 7) : null),
      ),
    );

/// Scripted backend: each call pops the next responder.
class FakeAiBackend implements AiBackendClient {
  FakeAiBackend(this.responders);

  final List<FutureOr<AiChatResponse> Function(AiChatRequest req)> responders;
  final requests = <AiChatRequest>[];

  @override
  AiBackendState get state => AiBackendState.ready;

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    requests.add(request);
    if (responders.isEmpty) {
      return text(request, 'done');
    }
    final r = responders.length == 1
        ? responders.first
        : responders.removeAt(0);
    return r(request);
  }

  static AiChatResponse text(AiChatRequest req, String text) => AiChatResponse(
    requestId: req.requestId,
    content: [
      {'type': 'text', 'text': text},
    ],
    stopReason: 'end_turn',
    inputTokens: 10,
    outputTokens: 5,
    provider: 'anthropic',
    model: 'claude-sonnet-5-5',
  );

  static AiChatResponse toolCall(
    AiChatRequest req,
    String id,
    String name, [
    Map<String, Object?> args = const {},
  ]) => AiChatResponse(
    requestId: req.requestId,
    content: [
      {'type': 'text', 'text': 'Let me check.'},
      {'type': 'tool_call', 'id': id, 'name': name, 'arguments': args},
    ],
    stopReason: 'tool_use',
    provider: 'anthropic',
    model: 'claude-sonnet-5-5',
  );

  @override
  Future<Map<String, Object?>> status() async => {};

  @override
  Future<Map<String, Object?>> testProviders({String? provider}) async => {};
}
