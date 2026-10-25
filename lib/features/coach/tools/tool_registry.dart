import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/water_repository.dart';
import 'activity_tools.dart';
import 'life_tools.dart';
import 'nutrition_tools.dart';
import 'tool_executor.dart';
import 'tool_spec.dart';

/// Every tool the coach agent can call, in the order sent to the model.
final List<ToolSpec> coachTools = [
  getTodayDashboardTool,
  getNutritionSummaryTool,
  searchFoodDatabaseTool,
  logFoodTool,
  updateFoodEntryTool,
  getWaterSummaryTool,
  logWaterTool,
  getStepsSummaryTool,
  getWorkoutHistoryTool,
  getStrengthProgressTool,
  getRunningActivitiesTool,
  getStravaActivitiesTool,
  analyzeStravaActivityTool,
  getCalendarEventsTool,
  suggestScheduleTool,
  getHabitSummaryTool,
  logMoodTool,
  getJournalSummaryTool,
  getCompetitionCountdownTool,
  getWeeklyReportTool,
  getProfileAndGoalsTool,
  rememberPreferenceTool,
  recordRecommendationTool,
];

ToolSpec? toolByName(String name) {
  for (final t in coachTools) {
    if (t.name == name) return t;
  }
  return null;
}

final toolExecutorProvider = Provider<ToolExecutor>((ref) {
  final db = ref.watch(databaseProvider);
  final clock = ref.watch(clockProvider);
  final water = ref.watch(waterRepositoryProvider);
  final calendar = ref.watch(calendarReaderProvider);
  return ToolExecutor(
    db: db,
    settings: ref.watch(settingsRepositoryProvider),
    tools: coachTools,
    contextFor: (conversationId, toolCallId) => ToolContext(
      db: db,
      clock: clock,
      water: water,
      calendar: calendar,
      conversationId: conversationId,
      toolCallId: toolCallId,
    ),
  );
});
