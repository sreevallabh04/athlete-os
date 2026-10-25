// Drift table definitions for Athlete OS.
//
// Conventions:
// * Primary keys are client-generated UUID strings so records can be created
//   offline and synced idempotently.
// * Instants are stored as UTC DateTime. `localDate` (YYYY-MM-DD) records the
//   user's calendar day at the time of logging so daily totals do not shift
//   when the device timezone changes.
// * `deletedAt` implements soft deletes so deletions can be synced.
// * Imported records keep `source` + `externalId` (unique together) to make
//   re-imports idempotent, and `rawJson` to preserve original source values.
import 'package:drift/drift.dart';

mixin Timestamps on Table {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

mixin SoftDelete on Table {
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

// ---------------------------------------------------------------------------
// Profile, goals, settings
// ---------------------------------------------------------------------------

/// Single-row table (id = 1) holding the user's profile and targets.
class UserProfiles extends Table with Timestamps {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get displayName => text().nullable()();
  RealColumn get heightCm => real().nullable()();
  RealColumn get targetWeightKg => real().nullable()();

  /// omnivore | vegetarian | eggetarian | vegan | pescatarian
  TextColumn get dietType => text().withDefault(const Constant('eggetarian'))();

  /// JSON array of strings.
  TextColumn get restrictionsJson => text().withDefault(const Constant('[]'))();

  /// JSON array of strings.
  TextColumn get dislikedFoodsJson =>
      text().withDefault(const Constant('[]'))();
  IntColumn get calorieTarget => integer().withDefault(const Constant(2000))();
  RealColumn get proteinTargetG => real().withDefault(const Constant(150))();
  RealColumn get carbsTargetG => real().withDefault(const Constant(200))();
  RealColumn get fatTargetG => real().withDefault(const Constant(60))();
  RealColumn get fiberTargetG => real().nullable()();
  IntColumn get stepGoal => integer().withDefault(const Constant(10000))();
  IntColumn get waterGoalMl => integer().withDefault(const Constant(3000))();

  /// Minutes after local midnight.
  IntColumn get wakeMinutes => integer().withDefault(const Constant(390))();
  IntColumn get sleepMinutes => integer().withDefault(const Constant(1350))();

  /// direct | encouraging | analytical
  TextColumn get coachingStyle =>
      text().withDefault(const Constant('direct'))();

  /// Free text describing training availability.
  TextColumn get trainingAvailability => text().nullable()();

  /// Running goal: distance (m) and target time (s). Default 5K < 30:00.
  IntColumn get runGoalDistanceM =>
      integer().withDefault(const Constant(5000))();
  IntColumn get runGoalTimeS => integer().withDefault(const Constant(1800))();
  TextColumn get fitnessGoals => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Audit trail of every change to a target/goal.
class GoalHistory extends Table {
  TextColumn get id => text()();
  TextColumn get metric => text()();
  TextColumn get oldValue => text().nullable()();
  TextColumn get newValue => text()();

  /// user | ai_approved
  TextColumn get changedBy => text().withDefault(const Constant('user'))();
  TextColumn get reason => text().nullable()();
  DateTimeColumn get changedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Generic key/value settings (JSON values) for feature flags, consents, etc.
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key};
}

/// Injuries or clinician-imposed restrictions the coach must respect.
class HealthRestrictions extends Table with Timestamps {
  TextColumn get id => text()();
  TextColumn get description => text()();
  TextColumn get bodyPart => text().nullable()();
  TextColumn get restriction => text().nullable()();
  BoolColumn get clinicianImposed =>
      boolean().withDefault(const Constant(false))();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDate => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Nutrition
// ---------------------------------------------------------------------------

/// A food definition. Nutrient values are per *one serving* as defined by
/// `servingSize` + `servingUnit`; `gramsPerServing` allows gram-based entry.
class Foods extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get brand => text().nullable()();
  TextColumn get barcode => text().nullable()();
  RealColumn get servingSize => real().withDefault(const Constant(100))();
  TextColumn get servingUnit => text().withDefault(const Constant('g'))();
  RealColumn get gramsPerServing => real().nullable()();
  RealColumn get calories => real()();
  RealColumn get proteinG => real().withDefault(const Constant(0))();
  RealColumn get carbsG => real().withDefault(const Constant(0))();
  RealColumn get fatG => real().withDefault(const Constant(0))();
  RealColumn get fiberG => real().nullable()();

  /// openfoodfacts | usda | custom | ai_estimate | quick_add
  TextColumn get source => text()();
  TextColumn get sourceId => text().nullable()();

  /// verified_label | database | user_entered | estimate
  TextColumn get verification => text()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  /// Original provider payload (subset) to preserve source values.
  TextColumn get rawJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One logged food item. Nutrient values are a *snapshot* computed at logging
/// time so later edits to the food definition don't rewrite history.
class FoodLogEntries extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get foodId => text().nullable().references(Foods, #id)();
  TextColumn get recipeId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get brand => text().nullable()();

  /// breakfast | lunch | dinner | snack
  TextColumn get mealType => text()();
  RealColumn get servings => real().withDefault(const Constant(1))();
  RealColumn get grams => real().nullable()();
  RealColumn get calories => real()();
  RealColumn get proteinG => real().withDefault(const Constant(0))();
  RealColumn get carbsG => real().withDefault(const Constant(0))();
  RealColumn get fatG => real().withDefault(const Constant(0))();
  RealColumn get fiberG => real().nullable()();
  TextColumn get source => text()();
  TextColumn get verification => text()();
  DateTimeColumn get loggedAt => dateTime()();
  TextColumn get localDate => text()();
  TextColumn get tzName => text()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Recipes extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get name => text()();
  RealColumn get servings => real().withDefault(const Constant(1))();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class RecipeIngredients extends Table {
  TextColumn get id => text()();
  TextColumn get recipeId =>
      text().references(Recipes, #id, onDelete: KeyAction.cascade)();
  TextColumn get foodId => text().nullable().references(Foods, #id)();
  TextColumn get name => text()();
  RealColumn get servings => real().withDefault(const Constant(1))();
  RealColumn get grams => real().nullable()();
  RealColumn get calories => real()();
  RealColumn get proteinG => real().withDefault(const Constant(0))();
  RealColumn get carbsG => real().withDefault(const Constant(0))();
  RealColumn get fatG => real().withDefault(const Constant(0))();
  RealColumn get fiberG => real().nullable()();
  TextColumn get verification =>
      text().withDefault(const Constant('user_entered'))();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Saved meals / meal templates.
class SavedMeals extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get mealType => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SavedMealItems extends Table {
  TextColumn get id => text()();
  TextColumn get savedMealId =>
      text().references(SavedMeals, #id, onDelete: KeyAction.cascade)();
  TextColumn get foodId => text().nullable().references(Foods, #id)();
  TextColumn get name => text()();
  RealColumn get servings => real().withDefault(const Constant(1))();
  RealColumn get grams => real().nullable()();
  RealColumn get calories => real()();
  RealColumn get proteinG => real().withDefault(const Constant(0))();
  RealColumn get carbsG => real().withDefault(const Constant(0))();
  RealColumn get fatG => real().withDefault(const Constant(0))();
  RealColumn get fiberG => real().nullable()();
  TextColumn get verification => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Hydration
// ---------------------------------------------------------------------------

class WaterLogs extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  IntColumn get amountMl => integer()();
  DateTimeColumn get loggedAt => dateTime()();
  TextColumn get localDate => text()();

  /// manual | notification | ai
  TextColumn get source => text().withDefault(const Constant('manual'))();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Health data (Health Connect / manual)
// ---------------------------------------------------------------------------

/// Individual health records (heart rate, weight, sleep sessions, exercise
/// sessions...). Steps/distance are stored as daily aggregates in
/// [DailyHealthSummaries] because Health Connect's aggregate API dedupes
/// overlapping phone + watch records.
class HealthSamples extends Table {
  TextColumn get id => text()();

  /// heart_rate | resting_heart_rate | weight | sleep_session |
  /// exercise_session | active_kcal | total_kcal
  TextColumn get type => text()();
  RealColumn get value => real()();
  TextColumn get unit => text()();
  DateTimeColumn get startAt => dateTime()();
  DateTimeColumn get endAt => dateTime()();
  TextColumn get localDate => text()();

  /// e.g. com.sec.android.app.shealth
  TextColumn get sourceApp => text().nullable()();

  /// watch | phone | scale | manual | unknown
  TextColumn get sourceDevice =>
      text().withDefault(const Constant('unknown'))();

  /// health_connect | manual
  TextColumn get origin => text()();
  TextColumn get externalId => text().nullable()();
  TextColumn get metadataJson => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {origin, type, externalId},
  ];
}

/// Deduplicated per-day aggregates (steps, distance, active minutes...).
class DailyHealthSummaries extends Table {
  TextColumn get localDate => text()();

  /// steps | distance_m | active_minutes | active_kcal | sleep_minutes
  TextColumn get type => text()();
  RealColumn get value => real()();
  TextColumn get unit => text()();

  /// health_connect | manual
  TextColumn get origin => text()();

  /// Human-readable list of contributing apps/devices.
  TextColumn get sourcesSummary => text().nullable()();
  DateTimeColumn get computedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {localDate, type, origin};
}

// ---------------------------------------------------------------------------
// Training (Hevy / manual) and cardio (Strava / Health Connect / manual)
// ---------------------------------------------------------------------------

class Workouts extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();

  /// hevy | manual | csv | health_connect
  TextColumn get source => text()();
  TextColumn get externalId => text().nullable()();
  TextColumn get title => text()();
  DateTimeColumn get startAt => dateTime()();
  DateTimeColumn get endAt => dateTime().nullable()();
  TextColumn get localDate => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get rawJson => text().nullable()();

  /// Provider-side updated_at for incremental sync.
  DateTimeColumn get sourceUpdatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {source, externalId},
  ];
}

class WorkoutExercises extends Table {
  TextColumn get id => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get name => text()();
  TextColumn get templateId => text().nullable()();

  /// Optional mapped primary muscle group (only when mapping is known).
  TextColumn get muscleGroup => text().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get supersetId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkoutSets extends Table {
  TextColumn get id => text()();
  TextColumn get exerciseId =>
      text().references(WorkoutExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();

  /// normal | warmup | dropset | failure
  TextColumn get setType => text().withDefault(const Constant('normal'))();
  RealColumn get weightKg => real().nullable()();
  IntColumn get reps => integer().nullable()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get durationS => integer().nullable()();
  RealColumn get rpe => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Runs and other cardio. NOTE: rows with source = 'strava' must never be
/// sent to an AI provider (Strava API Policy §5.3, effective 2026-06-01) and
/// must be refreshed or purged within 7 days (§6.2).
class CardioActivities extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();

  /// strava | health_connect | manual
  TextColumn get source => text()();
  TextColumn get externalId => text().nullable()();
  TextColumn get name => text().nullable()();

  /// run | walk | ride | hike | other (normalised)
  TextColumn get sportType => text()();
  DateTimeColumn get startAt => dateTime()();
  TextColumn get localDate => text()();
  TextColumn get tzName => text().nullable()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get movingTimeS => integer().nullable()();
  IntColumn get elapsedTimeS => integer().nullable()();
  RealColumn get elevationGainM => real().nullable()();
  RealColumn get avgHeartRate => real().nullable()();
  RealColumn get maxHeartRate => real().nullable()();
  RealColumn get avgSpeedMps => real().nullable()();
  RealColumn get calories => real().nullable()();

  /// JSON list of per-km splits:
  /// [{"distance_m":..,"moving_time_s":..,"avg_hr":..,"elev_diff_m":..}]
  TextColumn get splitsJson => text().nullable()();
  TextColumn get lapsJson => text().nullable()();
  TextColumn get rawJson => text().nullable()();

  /// When the record was last fetched from its provider (Strava cache rule).
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {source, externalId},
  ];
}

// ---------------------------------------------------------------------------
// Well-being, habits, planning
// ---------------------------------------------------------------------------

class MoodEntries extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get localDate => text()();
  DateTimeColumn get recordedAt => dateTime()();

  /// 1..5
  IntColumn get mood => integer()();
  IntColumn get energy => integer().nullable()();
  IntColumn get stress => integer().nullable()();
  IntColumn get sleepQuality => integer().nullable()();

  /// JSON array of strings.
  TextColumn get emotionTagsJson => text().withDefault(const Constant('[]'))();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class JournalEntries extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get localDate => text()();
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get gratitude => text().nullable()();
  TextColumn get prompt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Habits extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// health | fitness | nutrition | mind | productivity | other
  TextColumn get category => text().withDefault(const Constant('other'))();

  /// daily | weekly | custom
  TextColumn get scheduleType => text().withDefault(const Constant('daily'))();

  /// Bitmask Mon=1<<0 ... Sun=1<<6 for `custom`.
  IntColumn get daysMask => integer().withDefault(const Constant(127))();

  /// Target completions per week for `weekly`.
  IntColumn get targetPerWeek => integer().nullable()();

  /// JSON array of minutes-after-midnight reminder times.
  TextColumn get reminderTimesJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get notes => text().nullable()();
  TextColumn get dependsOnHabitId => text().nullable()();

  /// Optional automatic completion rule: water_goal | step_goal | food_logged
  TextColumn get autoRule => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class HabitCompletions extends Table {
  TextColumn get id => text()();
  TextColumn get habitId =>
      text().references(Habits, #id, onDelete: KeyAction.cascade)();
  TextColumn get localDate => text()();

  /// done | skipped
  TextColumn get status => text().withDefault(const Constant('done'))();
  DateTimeColumn get completedAt =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {habitId, localDate},
  ];
}

/// Daily priorities / tasks with carryover support.
class Tasks extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get localDate => text()();

  /// 1 = most important.
  IntColumn get priority => integer().withDefault(const Constant(2))();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get carriedFromDate => text().nullable()();
  TextColumn get project => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// References to Google Calendar events created by the app (with consent).
class CalendarEventRefs extends Table {
  TextColumn get id => text()();
  TextColumn get calendarId => text()();
  TextColumn get eventId => text()();

  /// workout | meal_prep | focus | habit | other
  TextColumn get kind => text()();
  DateTimeColumn get startAt => dateTime()();
  DateTimeColumn get endAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Competition prep
// ---------------------------------------------------------------------------

class Competitions extends Table with Timestamps, SoftDelete {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Calendar date of the event in the event's timezone (YYYY-MM-DD).
  TextColumn get eventDate => text()();

  /// IANA timezone of the event, e.g. Asia/Kolkata.
  TextColumn get tzName => text()();
  TextColumn get location => text().nullable()();
  TextColumn get division => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

class CompetitionMilestones extends Table with Timestamps {
  TextColumn get id => text()();
  TextColumn get competitionId =>
      text().references(Competitions, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();

  /// milestone | checklist
  TextColumn get kind => text().withDefault(const Constant('milestone'))();
  TextColumn get dueDate => text().nullable()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Progress photos are stored only on-device (app-private storage).
class ProgressPhotos extends Table {
  TextColumn get id => text()();
  TextColumn get localPath => text()();
  DateTimeColumn get takenAt => dateTime()();
  TextColumn get localDate => text()();
  TextColumn get pose => text().nullable()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// AI agent
// ---------------------------------------------------------------------------

class AiConversations extends Table with Timestamps {
  TextColumn get id => text()();
  TextColumn get title => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class AiMessages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(AiConversations, #id, onDelete: KeyAction.cascade)();

  /// user | assistant | tool
  TextColumn get role => text()();

  /// Normalised content blocks as JSON.
  TextColumn get contentJson => text()();
  TextColumn get provider => text().nullable()();
  TextColumn get model => text().nullable()();
  IntColumn get inputTokens => integer().nullable()();
  IntColumn get outputTokens => integer().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Audit log of every tool the agent invoked.
class AiToolActions extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().nullable()();
  TextColumn get toolName => text()();
  TextColumn get argsJson => text()();
  TextColumn get resultSummary => text().nullable()();

  /// ok | error | rejected | pending_confirmation | confirmed
  TextColumn get status => text()();
  BoolColumn get isWrite => boolean().withDefault(const Constant(false))();

  /// Prevents duplicate side effects when a request is retried.
  TextColumn get idempotencyKey => text().unique()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get confirmedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// User-approved long-term memory for coaching.
class AiMemories extends Table with Timestamps {
  TextColumn get id => text()();

  /// preference | goal | routine | context
  TextColumn get category => text()();
  TextColumn get content => text()();

  /// user | ai_suggested
  TextColumn get origin => text().withDefault(const Constant('user'))();
  BoolColumn get approved => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// History of AI recommendations and the user's response.
class AiRecommendations extends Table {
  TextColumn get id => text()();

  /// habit | nutrition | training | schedule | general
  TextColumn get kind => text()();
  TextColumn get content => text()();

  /// pending | accepted | edited | dismissed
  TextColumn get status => text().withDefault(const Constant('pending'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get respondedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Integrations, sync, notifications, reports
// ---------------------------------------------------------------------------

class IntegrationConnections extends Table {
  /// health_connect | hevy | strava | google_calendar | open_food_facts |
  /// usda | ai_backend
  TextColumn get provider => text()();

  /// connected | disconnected | needs_setup | error | awaiting_credentials
  TextColumn get status => text()();
  TextColumn get scopesJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get connectedAt => dateTime().nullable()();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();

  /// Provider-specific incremental sync cursor.
  TextColumn get cursor => text().nullable()();
  TextColumn get metaJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {provider};
}

/// Pending operations to push to the backend (offline-first sync).
class SyncQueue extends Table {
  TextColumn get id => text()();
  TextColumn get entityTable => text()();
  TextColumn get entityId => text()();

  /// upsert | delete
  TextColumn get op => text()();
  TextColumn get payloadJson => text()();
  TextColumn get idempotencyKey => text().unique()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get nextAttemptAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class NotificationPrefs extends Table {
  /// water | habit | planning | mood | meal | steps | workout | competition |
  /// eod_review | weekly_summary
  TextColumn get kind => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();

  /// Kind-specific JSON config (interval, times, windows...).
  TextColumn get configJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {kind};
}

class Reports extends Table {
  TextColumn get id => text()();

  /// weekly | monthly
  TextColumn get kind => text()();
  TextColumn get periodStart => text()();
  TextColumn get periodEnd => text()();
  TextColumn get contentJson => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
