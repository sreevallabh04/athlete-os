import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../data/metrics_queries.dart';
import '../data/planning_repository.dart';
import '../domain/countdown.dart';
import '../domain/metrics.dart';
import '../domain/task_rules.dart';

/// The device's IANA timezone, or null when it can't be determined (tests,
/// unsupported platforms). Never throws.
final deviceTimeZoneProvider = FutureProvider<String?>((ref) async {
  try {
    final info = await FlutterTimezone.getLocalTimezone().timeout(
      const Duration(seconds: 2),
    );
    final id = info.identifier;
    return isValidTimeZone(id) ? id : null;
  } catch (_) {
    return null;
  }
});

class CompetitionView {
  const CompetitionView({
    required this.competition,
    required this.countdown,
    this.prepStartOverride,
  });
  final Competition competition;
  final CountdownResult countdown;

  /// User-set prep start (YYYY-MM-DD), when set.
  final String? prepStartOverride;
}

Future<CompetitionView?> loadCompetitionView(
  PlanningRepository repo,
  DateTime now,
) async {
  final comp = await repo.primaryCompetition();
  if (comp == null) return null;
  final prep = await repo.prepStart(comp.id);
  try {
    return CompetitionView(
      competition: comp,
      prepStartOverride: prep,
      countdown: CompetitionCountdown.compute(
        eventDate: comp.eventDate,
        tzName: comp.tzName,
        now: now,
        prepStartDate: prep,
        createdAt: comp.createdAt,
      ),
    );
  } on ArgumentError {
    return null;
  }
}

final competitionViewProvider = StreamProvider<CompetitionView?>((ref) {
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(planningRepositoryProvider);
  final clock = ref.watch(clockProvider);
  return watchTables(db, {
    db.competitions,
    db.appSettings,
  }, () => loadCompetitionView(repo, clock.now()));
});

final milestonesProvider = StreamProvider.autoDispose
    .family<List<CompetitionMilestone>, String>(
      (ref, competitionId) =>
          ref.watch(planningRepositoryProvider).watchMilestones(competitionId),
    );

final progressPhotosProvider = StreamProvider<List<ProgressPhoto>>(
  (ref) => ref.watch(planningRepositoryProvider).watchPhotos(),
);

final savedReportsProvider = StreamProvider<List<Report>>(
  (ref) => ref.watch(planningRepositoryProvider).watchReports(),
);

final restrictionsProvider = StreamProvider<List<HealthRestriction>>(
  (ref) => ref.watch(planningRepositoryProvider).watchRestrictions(),
);

/// Ordered tasks for a date (manual order, then priority).
final tasksForDateProvider = StreamProvider.autoDispose
    .family<List<TaskItem>, String>((ref, date) {
      final db = ref.watch(databaseProvider);
      final repo = ref.watch(planningRepositoryProvider);
      return watchTables(db, {db.tasks, db.appSettings}, () async {
        final tasks = await repo.tasksOn(date);
        final order = await repo.taskOrder(date);
        return orderTasks(tasks.map(taskItemOf), order);
      });
    });

/// Calendar events for a local date via the provider-agnostic reader.
final calendarDayProvider = FutureProvider.autoDispose
    .family<CalendarReadResult, String>((ref, date) async {
      final reader = ref.watch(calendarReaderProvider);
      final (start, end) = LocalDates.bounds(date);
      try {
        return await reader.eventsBetween(start, end);
      } catch (e) {
        return CalendarReadResult.failed(e.toString());
      }
    });

/// Data for the competition weekly progress review.
class ProgressReviewData {
  const ProgressReviewData({
    required this.today,
    required this.weights,
    required this.nutrition,
    required this.calorieTarget,
    required this.proteinTargetG,
    required this.workouts,
    required this.cardio,
  });
  final String today;
  final List<WeightPoint> weights;
  final Map<String, DayNutrition> nutrition;
  final int calorieTarget;
  final double proteinTargetG;
  final List<WorkoutRecord> workouts;
  final List<CardioRecord> cardio;
}

final progressReviewProvider = StreamProvider<ProgressReviewData>((ref) {
  final db = ref.watch(databaseProvider);
  final q = ref.watch(metricsQueriesProvider);
  final clock = ref.watch(clockProvider);
  return watchTables(
    db,
    {
      db.healthSamples,
      db.foodLogEntries,
      db.workouts,
      db.cardioActivities,
      db.userProfiles,
    },
    () async {
      final today = LocalDates.key(clock.now());
      final eightWeeks = weekStarts(today, 8).first;
      final from = LocalDates.addDays(today, -55);
      final start = from.compareTo(eightWeeks) < 0 ? from : eightWeeks;
      final profile = await (db.select(
        db.userProfiles,
      )..where((p) => p.id.equals(1))).getSingle();
      return ProgressReviewData(
        today: today,
        weights: await q.weights(start, today),
        nutrition: await q.nutritionByDay(
          LocalDates.addDays(today, -27),
          today,
        ),
        calorieTarget: profile.calorieTarget,
        proteinTargetG: profile.proteinTargetG,
        workouts: await q.workouts(start, today),
        cardio: await q.cardio(start, today),
      );
    },
  );
});
