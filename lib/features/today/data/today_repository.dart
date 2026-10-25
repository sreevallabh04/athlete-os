import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../planning/application/planning_providers.dart';
import '../../planning/data/metrics_queries.dart';
import '../../planning/data/planning_repository.dart';
import '../../planning/domain/habit_schedule.dart';
import '../../planning/domain/metrics.dart';
import '../../planning/domain/task_rules.dart';

/// Everything the Today dashboard shows, loaded in one pass. Every field is
/// nullable/empty when its data does not exist — nothing is defaulted to a
/// fake value.
class TodaySnapshot {
  const TodaySnapshot({
    required this.now,
    required this.date,
    required this.profile,
    required this.competition,
    required this.steps,
    required this.distance,
    required this.activeMinutes,
    required this.sleep,
    required this.latestHeartRate,
    required this.latestWorkout,
    required this.latestWorkoutExercises,
    required this.workoutToday,
    required this.weekRuns,
    required this.nutrition,
    required this.mealsLogged,
    required this.nutritionLastLoggedAt,
    required this.waterMl,
    required this.waterLastLoggedAt,
    required this.habitTally,
    required this.habitCount,
    required this.moodToday,
    required this.journalToday,
    required this.topTasks,
    required this.taskCount,
    required this.tasksDone,
    required this.plannedWorkout,
  });

  final DateTime now;
  final String date;
  final UserProfile profile;
  final CompetitionView? competition;
  final DailyMetric? steps;
  final DailyMetric? distance;
  final DailyMetric? activeMinutes;
  final DailyMetric? sleep;
  final HealthSample? latestHeartRate;
  final Workout? latestWorkout;
  final int latestWorkoutExercises;
  final Workout? workoutToday;
  final RunSummary weekRuns;
  final DayNutrition nutrition;
  final int mealsLogged;
  final DateTime? nutritionLastLoggedAt;
  final int waterMl;
  final DateTime? waterLastLoggedAt;
  final HabitTally habitTally;
  final int habitCount;
  final MoodEntry? moodToday;
  final bool journalToday;
  final List<TaskItem> topTasks;
  final int taskCount;
  final int tasksDone;

  /// Title of an undone task tagged "Workout" today, if any.
  final String? plannedWorkout;
}

class TodayRepository {
  TodayRepository(this._db, this._planning, this._metrics);
  final AppDatabase _db;
  final PlanningRepository _planning;
  final MetricsQueries _metrics;

  /// Tables whose changes should refresh the dashboard.
  Set<ResultSetImplementation<dynamic, dynamic>> get watchedTables => {
    _db.userProfiles,
    _db.competitions,
    _db.appSettings,
    _db.dailyHealthSummaries,
    _db.healthSamples,
    _db.workouts,
    _db.cardioActivities,
    _db.foodLogEntries,
    _db.waterLogs,
    _db.habits,
    _db.habitCompletions,
    _db.moodEntries,
    _db.journalEntries,
    _db.tasks,
  };

  Future<TodaySnapshot> load(DateTime now) async {
    final date = LocalDates.key(now);
    final profile = await (_db.select(
      _db.userProfiles,
    )..where((p) => p.id.equals(1))).getSingle();

    Future<DailyMetric?> daily(String type) async =>
        preferHealthConnect(await _metrics.daily(type, date, date))[date];

    final hr =
        await (_db.select(_db.healthSamples)
              ..where((s) => s.type.equals('heart_rate'))
              ..orderBy([(s) => OrderingTerm.desc(s.endAt)])
              ..limit(1))
            .getSingleOrNull();

    final latestWorkout =
        await (_db.select(_db.workouts)
              ..where((w) => w.deletedAt.isNull())
              ..orderBy([(w) => OrderingTerm.desc(w.startAt)])
              ..limit(1))
            .getSingleOrNull();
    var exerciseCount = 0;
    if (latestWorkout != null) {
      exerciseCount = (await (_db.select(
        _db.workoutExercises,
      )..where((e) => e.workoutId.equals(latestWorkout.id))).get()).length;
    }

    final weekStart = LocalDates.weekStart(date);
    final weekRuns = summarizeRuns(await _metrics.cardio(weekStart, date));

    final food = await _metrics.foodEntries(date, date);
    final nutrition =
        (await _metrics.nutritionByDay(date, date))[date] ??
        DayNutrition(date: date);

    final water = await (_db.select(
      _db.waterLogs,
    )..where((w) => w.localDate.equals(date) & w.deletedAt.isNull())).get();

    final habits = await _metrics.habits();
    final marks = await _metrics.habitMarks(weekStart, date);

    final mood =
        await (_db.select(_db.moodEntries)
              ..where((m) => m.localDate.equals(date) & m.deletedAt.isNull())
              ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)])
              ..limit(1))
            .getSingleOrNull();
    final journal =
        await (_db.select(_db.journalEntries)
              ..where((j) => j.localDate.equals(date) & j.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();

    final tasks = (await _planning.tasksOn(date)).map(taskItemOf).toList();
    final order = await _planning.taskOrder(date);
    final planned = orderTasks(tasks, order)
        .where((t) => !t.done && (t.project?.toLowerCase() ?? '') == 'workout')
        .firstOrNull;

    return TodaySnapshot(
      now: now,
      date: date,
      profile: profile,
      competition: await loadCompetitionView(_planning, now),
      steps: await daily('steps'),
      distance: await daily('distance_m'),
      activeMinutes: await daily('active_minutes'),
      sleep: await daily('sleep_minutes'),
      latestHeartRate: hr,
      latestWorkout: latestWorkout,
      latestWorkoutExercises: exerciseCount,
      workoutToday: latestWorkout?.localDate == date ? latestWorkout : null,
      weekRuns: weekRuns,
      nutrition: nutrition,
      mealsLogged: food.map((f) => f.mealType).toSet().length,
      nutritionLastLoggedAt: food.isEmpty ? null : food.last.loggedAt,
      waterMl: water.fold(0, (s, w) => s + w.amountMl),
      waterLastLoggedAt: water.isEmpty
          ? null
          : water.map((w) => w.loggedAt).reduce((a, b) => a.isAfter(b) ? a : b),
      habitTally: tallyHabits(habits, date, marks),
      habitCount: habits.length,
      moodToday: mood,
      journalToday: journal != null,
      topTasks: topPriorities(tasks, order),
      taskCount: tasks.length,
      tasksDone: tasks.where((t) => t.done).length,
      plannedWorkout: planned?.title,
    );
  }
}
