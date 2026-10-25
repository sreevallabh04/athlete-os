import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    UserProfiles,
    GoalHistory,
    AppSettings,
    HealthRestrictions,
    Foods,
    FoodLogEntries,
    Recipes,
    RecipeIngredients,
    SavedMeals,
    SavedMealItems,
    WaterLogs,
    HealthSamples,
    DailyHealthSummaries,
    Workouts,
    WorkoutExercises,
    WorkoutSets,
    CardioActivities,
    MoodEntries,
    JournalEntries,
    Habits,
    HabitCompletions,
    Tasks,
    CalendarEventRefs,
    Competitions,
    CompetitionMilestones,
    ProgressPhotos,
    AiConversations,
    AiMessages,
    AiToolActions,
    AiMemories,
    AiRecommendations,
    IntegrationConnections,
    SyncQueue,
    NotificationPrefs,
    Reports,
    MessagingAppSettings,
    MessagingContactRules,
    CapturedNotifications,
    ReplyDrafts,
    AutomationAudit,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'athlete_os'));

  /// In-memory or custom executor, used by tests.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
      await _createAssistantIndexes();
      // Seed the single profile row with editable example targets.
      await into(userProfiles).insert(const UserProfilesCompanion());
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(messagingAppSettings);
        await m.createTable(messagingContactRules);
        await m.createTable(capturedNotifications);
        await m.createTable(replyDrafts);
        await m.createTable(automationAudit);
        await _createAssistantIndexes();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createIndexes() async {
    const statements = [
      'CREATE INDEX IF NOT EXISTS idx_food_log_date ON food_log_entries(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_foods_barcode ON foods(barcode)',
      'CREATE INDEX IF NOT EXISTS idx_foods_name ON foods(name)',
      'CREATE INDEX IF NOT EXISTS idx_water_date ON water_logs(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_health_type_date ON health_samples(type, local_date)',
      'CREATE INDEX IF NOT EXISTS idx_workouts_start ON workouts(start_at)',
      'CREATE INDEX IF NOT EXISTS idx_cardio_start ON cardio_activities(start_at)',
      'CREATE INDEX IF NOT EXISTS idx_mood_date ON mood_entries(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_journal_date ON journal_entries(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_habit_completion_date ON habit_completions(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(local_date)',
      'CREATE INDEX IF NOT EXISTS idx_sync_next ON sync_queue(next_attempt_at)',
      'CREATE INDEX IF NOT EXISTS idx_ai_messages_conv ON ai_messages(conversation_id, created_at)',
    ];
    for (final s in statements) {
      await customStatement(s);
    }
  }

  Future<void> _createAssistantIndexes() async {
    const statements = [
      'CREATE INDEX IF NOT EXISTS idx_captured_pkg_time ON captured_notifications(package_name, posted_at)',
      'CREATE INDEX IF NOT EXISTS idx_captured_expires ON captured_notifications(expires_at)',
      'CREATE INDEX IF NOT EXISTS idx_drafts_status ON reply_drafts(status, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_audit_time ON automation_audit(created_at)',
    ];
    for (final s in statements) {
      await customStatement(s);
    }
  }
}
