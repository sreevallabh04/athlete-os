import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/countdown.dart';
import '../domain/habit_schedule.dart';
import '../domain/metrics.dart';
import '../domain/report_builder.dart';

/// Read-only Drift queries over tables filled by other features (nutrition,
/// health, training, life). Results are mapped to storage-independent domain
/// records so the pure builders stay testable.
class MetricsQueries {
  MetricsQueries(this._db);
  final AppDatabase _db;

  Future<Map<String, DayNutrition>> nutritionByDay(
    String start,
    String end,
  ) async {
    final rows =
        await (_db.select(_db.foodLogEntries)..where(
              (f) =>
                  f.localDate.isBetweenValues(start, end) &
                  f.deletedAt.isNull(),
            ))
            .get();
    final out = <String, DayNutrition>{};
    for (final r in rows) {
      final d = out[r.localDate];
      out[r.localDate] = DayNutrition(
        date: r.localDate,
        kcal: (d?.kcal ?? 0) + r.calories,
        proteinG: (d?.proteinG ?? 0) + r.proteinG,
        carbsG: (d?.carbsG ?? 0) + r.carbsG,
        fatG: (d?.fatG ?? 0) + r.fatG,
        entries: (d?.entries ?? 0) + 1,
      );
    }
    return out;
  }

  Future<List<FoodLogEntry>> foodEntries(String start, String end) =>
      (_db.select(_db.foodLogEntries)
            ..where(
              (f) =>
                  f.localDate.isBetweenValues(start, end) &
                  f.deletedAt.isNull(),
            )
            ..orderBy([(f) => OrderingTerm.asc(f.loggedAt)]))
          .get();

  Future<List<WeightPoint>> weights(String start, String end) async {
    final rows =
        await (_db.select(_db.healthSamples)
              ..where(
                (s) =>
                    s.type.equals('weight') &
                    s.localDate.isBetweenValues(start, end),
              )
              ..orderBy([(s) => OrderingTerm.asc(s.startAt)]))
            .get();
    return [for (final r in rows) _weight(r)];
  }

  Future<WeightPoint?> latestWeight() async {
    final r =
        await (_db.select(_db.healthSamples)
              ..where((s) => s.type.equals('weight'))
              ..orderBy([(s) => OrderingTerm.desc(s.startAt)])
              ..limit(1))
            .getSingleOrNull();
    return r == null ? null : _weight(r);
  }

  WeightPoint _weight(HealthSample r) => WeightPoint(
    date: r.localDate,
    at: r.startAt,
    kg: r.value,
    origin: r.origin,
  );

  Future<List<DailyMetric>> daily(String type, String start, String end) async {
    final rows =
        await (_db.select(_db.dailyHealthSummaries)..where(
              (s) =>
                  s.type.equals(type) & s.localDate.isBetweenValues(start, end),
            ))
            .get();
    return [
      for (final r in rows)
        DailyMetric(
          date: r.localDate,
          value: r.value,
          origin: r.origin,
          computedAt: r.computedAt,
          sourcesSummary: r.sourcesSummary,
        ),
    ];
  }

  Future<List<CardioRecord>> cardio(String start, String end) async {
    final rows =
        await (_db.select(_db.cardioActivities)
              ..where(
                (c) =>
                    c.localDate.isBetweenValues(start, end) &
                    c.deletedAt.isNull(),
              )
              ..orderBy([(c) => OrderingTerm.asc(c.startAt)]))
            .get();
    return [
      for (final r in rows)
        CardioRecord(
          date: r.localDate,
          sportType: r.sportType,
          source: r.source,
          startAt: r.startAt,
          distanceM: r.distanceM,
          movingTimeS: r.movingTimeS,
          name: r.name,
        ),
    ];
  }

  Future<List<WorkoutRecord>> workouts(String start, String end) async {
    final rows =
        await (_db.select(_db.workouts)
              ..where(
                (w) =>
                    w.localDate.isBetweenValues(start, end) &
                    w.deletedAt.isNull(),
              )
              ..orderBy([(w) => OrderingTerm.asc(w.startAt)]))
            .get();
    return [
      for (final w in rows)
        WorkoutRecord(
          id: w.id,
          title: w.title,
          date: w.localDate,
          source: w.source,
          startAt: w.startAt,
        ),
    ];
  }

  Future<List<StrengthSet>> sets(String start, String end) async {
    final q =
        _db.select(_db.workoutSets).join([
          innerJoin(
            _db.workoutExercises,
            _db.workoutExercises.id.equalsExp(_db.workoutSets.exerciseId),
          ),
          innerJoin(
            _db.workouts,
            _db.workouts.id.equalsExp(_db.workoutExercises.workoutId),
          ),
        ])..where(
          _db.workouts.localDate.isBetweenValues(start, end) &
              _db.workouts.deletedAt.isNull(),
        );
    final rows = await q.get();
    return [
      for (final r in rows)
        () {
          final s = r.readTable(_db.workoutSets);
          final e = r.readTable(_db.workoutExercises);
          final w = r.readTable(_db.workouts);
          return StrengthSet(
            workoutId: w.id,
            date: w.localDate,
            exercise: e.name,
            setType: s.setType,
            weightKg: s.weightKg,
            reps: s.reps,
          );
        }(),
    ];
  }

  /// ml per day for days with at least one log.
  Future<Map<String, int>> waterByDay(String start, String end) async {
    final rows =
        await (_db.select(_db.waterLogs)..where(
              (w) =>
                  w.localDate.isBetweenValues(start, end) &
                  w.deletedAt.isNull(),
            ))
            .get();
    final out = <String, int>{};
    for (final r in rows) {
      out.update(
        r.localDate,
        (v) => v + r.amountMl,
        ifAbsent: () => r.amountMl,
      );
    }
    return out;
  }

  Future<List<HabitSpec>> habits() async {
    final rows =
        await (_db.select(_db.habits)
              ..where((h) => h.deletedAt.isNull() & h.archived.equals(false))
              ..orderBy([(h) => OrderingTerm.asc(h.sortOrder)]))
            .get();
    return [
      for (final h in rows)
        HabitSpec(
          id: h.id,
          name: h.name,
          scheduleType: h.scheduleType,
          daysMask: h.daysMask,
          targetPerWeek: h.targetPerWeek,
          archived: h.archived,
        ),
    ];
  }

  Future<List<HabitMark>> habitMarks(String start, String end) async {
    final rows = await (_db.select(
      _db.habitCompletions,
    )..where((c) => c.localDate.isBetweenValues(start, end))).get();
    return [for (final c in rows) HabitMark(c.habitId, c.localDate, c.status)];
  }

  Future<List<MoodPoint>> moods(String start, String end) async {
    final rows =
        await (_db.select(_db.moodEntries)..where(
              (m) =>
                  m.localDate.isBetweenValues(start, end) &
                  m.deletedAt.isNull(),
            ))
            .get();
    return [
      for (final m in rows)
        MoodPoint(date: m.localDate, mood: m.mood, energy: m.energy),
    ];
  }

  Future<Competition?> primaryCompetition() =>
      (_db.select(_db.competitions)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([
              (c) => OrderingTerm.desc(c.isPrimary),
              (c) => OrderingTerm.asc(c.eventDate),
            ])
            ..limit(1))
          .getSingleOrNull();

  /// Gathers everything [ReportBuilder] needs for one period.
  Future<ReportInput> reportInput({
    required String kind,
    required String start,
    required String end,
    required DateTime now,
  }) async {
    final profile = await (_db.select(
      _db.userProfiles,
    )..where((p) => p.id.equals(1))).getSingle();
    // Habit marks for weekly targets need the whole first week.
    final marksFrom = LocalDates.weekStart(start);
    final comp = await primaryCompetition();
    String? compLine;
    if (comp != null) {
      try {
        compLine = CompetitionCountdown.compute(
          eventDate: comp.eventDate,
          tzName: comp.tzName,
          now: now,
        ).headline(comp.name);
      } catch (_) {
        compLine = null;
      }
    }
    return ReportInput(
      kind: kind,
      periodStart: start,
      periodEnd: end,
      asOfDate: LocalDates.key(now),
      targets: ReportTargets(
        calorieTarget: profile.calorieTarget,
        proteinTargetG: profile.proteinTargetG,
        stepGoal: profile.stepGoal,
        waterGoalMl: profile.waterGoalMl,
      ),
      nutrition: await nutritionByDay(start, end),
      weights: await weights(start, end),
      steps: await daily('steps', start, end),
      sleep: await daily('sleep_minutes', start, end),
      cardio: await cardio(start, end),
      workouts: await workouts(start, end),
      sets: await sets(start, end),
      water: await waterByDay(start, end),
      habits: await habits(),
      habitMarks: await habitMarks(marksFrom, end),
      moods: await moods(start, end),
      competitionLine: compLine,
    );
  }
}

final metricsQueriesProvider = Provider<MetricsQueries>(
  (ref) => MetricsQueries(ref.watch(databaseProvider)),
);

/// Re-runs [load] whenever any of [tables] changes. Lets dashboards stay live
/// without bespoke watch queries for every aggregate.
Stream<T> watchTables<T>(
  AppDatabase db,
  Set<ResultSetImplementation<dynamic, dynamic>> tables,
  Future<T> Function() load,
) async* {
  yield await load();
  await for (final _ in db.tableUpdates(TableUpdateQuery.onAllTables(tables))) {
    yield await load();
  }
}
