import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/settings_repository.dart';
import '../domain/task_rules.dart';

/// Setting-key helpers owned by the planning feature.
abstract final class PlanningKeys {
  static String taskOrder(String date) => 'planner.order.$date';
  static String carryoverDismissed(String date) =>
      'planner.carryover_dismissed.$date';
  static String dayReview(String date) => 'review.$date';
  static String prepStart(String competitionId) =>
      'competition.prep_start.$competitionId';
}

TaskItem taskItemOf(Task t) => TaskItem(
  id: t.id,
  title: t.title,
  localDate: t.localDate,
  priority: t.priority,
  done: t.done,
  carriedFromDate: t.carriedFromDate,
  project: t.project,
  deleted: t.deletedAt != null,
  createdAt: t.createdAt,
);

/// Writes for tables owned by the planning feature: tasks, competitions,
/// milestones, progress-photo rows, reports and health restrictions.
class PlanningRepository {
  PlanningRepository(this._db, this._settings, this._clock);
  final AppDatabase _db;
  final SettingsRepository _settings;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  // ---------------------------------------------------------------- tasks

  Stream<List<Task>> watchTasks(String date) => (_db.select(
    _db.tasks,
  )..where((t) => t.localDate.equals(date) & t.deletedAt.isNull())).watch();

  Future<List<Task>> tasksOn(String date) => (_db.select(
    _db.tasks,
  )..where((t) => t.localDate.equals(date) & t.deletedAt.isNull())).get();

  Future<List<Task>> tasksBetween(String start, String end) =>
      (_db.select(_db.tasks)..where(
            (t) =>
                t.localDate.isBetweenValues(start, end) & t.deletedAt.isNull(),
          ))
          .get();

  Future<String> addTask({
    required String title,
    required String date,
    int priority = 2,
    String? project,
  }) async {
    final id = newId();
    await _db
        .into(_db.tasks)
        .insert(
          TasksCompanion.insert(
            id: id,
            title: title.trim(),
            localDate: date,
            priority: Value(priority.clamp(1, 3)),
            project: Value(_blankToNull(project)),
            createdAt: Value(_nowUtc),
            updatedAt: Value(_nowUtc),
          ),
        );
    return id;
  }

  Future<void> updateTask(
    String id, {
    required String title,
    required int priority,
    String? project,
  }) => (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
    TasksCompanion(
      title: Value(title.trim()),
      priority: Value(priority.clamp(1, 3)),
      project: Value(_blankToNull(project)),
      updatedAt: Value(_nowUtc),
    ),
  );

  Future<void> setTaskDone(String id, bool done) =>
      (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          done: Value(done),
          completedAt: Value(done ? _nowUtc : null),
          updatedAt: Value(_nowUtc),
        ),
      );

  Future<void> deleteTask(String id) =>
      (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(deletedAt: Value(_nowUtc), updatedAt: Value(_nowUtc)),
      );

  /// Moves the chosen undone tasks to [toDate], recording where each came
  /// from. Only called after the user explicitly confirms.
  Future<int> carryOver(Iterable<String> ids, String toDate) async {
    var moved = 0;
    await _db.transaction(() async {
      for (final id in ids) {
        final t = await (_db.select(
          _db.tasks,
        )..where((x) => x.id.equals(id))).getSingleOrNull();
        if (t == null || t.done || t.deletedAt != null) continue;
        await (_db.update(_db.tasks)..where((x) => x.id.equals(id))).write(
          TasksCompanion(
            localDate: Value(toDate),
            carriedFromDate: Value(t.carriedFromDate ?? t.localDate),
            updatedAt: Value(_nowUtc),
          ),
        );
        moved++;
      }
    });
    return moved;
  }

  Future<List<String>> taskOrder(String date) async =>
      ((await _settings.get<List<dynamic>>(PlanningKeys.taskOrder(date))) ??
              const [])
          .cast<String>();

  Stream<List<String>> watchTaskOrder(String date) => _settings
      .watch<List<dynamic>>(PlanningKeys.taskOrder(date))
      .map((v) => (v ?? const []).cast<String>());

  Future<void> setTaskOrder(String date, List<String> ids) =>
      _settings.set(PlanningKeys.taskOrder(date), ids);

  // ---------------------------------------------------------- competition

  Stream<Competition?> watchPrimaryCompetition() =>
      (_db.select(_db.competitions)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([
              (c) => OrderingTerm.desc(c.isPrimary),
              (c) => OrderingTerm.asc(c.eventDate),
            ])
            ..limit(1))
          .watchSingleOrNull();

  Future<Competition?> primaryCompetition() =>
      (_db.select(_db.competitions)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([
              (c) => OrderingTerm.desc(c.isPrimary),
              (c) => OrderingTerm.asc(c.eventDate),
            ])
            ..limit(1))
          .getSingleOrNull();

  Future<String> saveCompetition({
    String? id,
    required String name,
    required String eventDate,
    required String tzName,
    String? location,
    String? division,
    String? notes,
  }) async {
    final rowId = id ?? newId();
    final now = _nowUtc;
    if (id == null) {
      await _db
          .into(_db.competitions)
          .insert(
            CompetitionsCompanion.insert(
              id: rowId,
              name: name.trim(),
              eventDate: eventDate,
              tzName: tzName,
              location: Value(_blankToNull(location)),
              division: Value(_blankToNull(division)),
              notes: Value(_blankToNull(notes)),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    } else {
      await (_db.update(_db.competitions)..where((c) => c.id.equals(id))).write(
        CompetitionsCompanion(
          name: Value(name.trim()),
          eventDate: Value(eventDate),
          tzName: Value(tzName),
          location: Value(_blankToNull(location)),
          division: Value(_blankToNull(division)),
          notes: Value(_blankToNull(notes)),
          updatedAt: Value(now),
        ),
      );
    }
    return rowId;
  }

  Future<void> deleteCompetition(String id) =>
      (_db.update(_db.competitions)..where((c) => c.id.equals(id))).write(
        CompetitionsCompanion(deletedAt: Value(_nowUtc)),
      );

  Future<String?> prepStart(String competitionId) =>
      _settings.get<String>(PlanningKeys.prepStart(competitionId));

  Stream<String?> watchPrepStart(String competitionId) =>
      _settings.watch<String>(PlanningKeys.prepStart(competitionId));

  Future<void> setPrepStart(String competitionId, String? date) =>
      _settings.set(PlanningKeys.prepStart(competitionId), date);

  Stream<List<CompetitionMilestone>> watchMilestones(String competitionId) =>
      (_db.select(_db.competitionMilestones)
            ..where((m) => m.competitionId.equals(competitionId))
            ..orderBy([
              (m) => OrderingTerm.asc(m.done),
              (m) =>
                  OrderingTerm(expression: m.dueDate, nulls: NullsOrder.last),
              (m) => OrderingTerm.asc(m.sortOrder),
            ]))
          .watch();

  Future<void> addMilestone({
    required String competitionId,
    required String title,
    String kind = 'milestone',
    String? dueDate,
  }) async {
    final count = await (_db.select(
      _db.competitionMilestones,
    )..where((m) => m.competitionId.equals(competitionId))).get();
    await _db
        .into(_db.competitionMilestones)
        .insert(
          CompetitionMilestonesCompanion.insert(
            id: newId(),
            competitionId: competitionId,
            title: title.trim(),
            kind: Value(kind),
            dueDate: Value(dueDate),
            sortOrder: Value(count.length),
          ),
        );
  }

  Future<void> updateMilestone(
    String id, {
    required String title,
    required String kind,
    String? dueDate,
  }) => (_db.update(_db.competitionMilestones)..where((m) => m.id.equals(id)))
      .write(
        CompetitionMilestonesCompanion(
          title: Value(title.trim()),
          kind: Value(kind),
          dueDate: Value(dueDate),
          updatedAt: Value(_nowUtc),
        ),
      );

  Future<void> setMilestoneDone(String id, bool done) =>
      (_db.update(
        _db.competitionMilestones,
      )..where((m) => m.id.equals(id))).write(
        CompetitionMilestonesCompanion(
          done: Value(done),
          updatedAt: Value(_nowUtc),
        ),
      );

  Future<void> deleteMilestone(String id) => (_db.delete(
    _db.competitionMilestones,
  )..where((m) => m.id.equals(id))).go();

  // ------------------------------------------------------- progress photos

  Stream<List<ProgressPhoto>> watchPhotos() => (_db.select(
    _db.progressPhotos,
  )..orderBy([(p) => OrderingTerm.desc(p.takenAt)])).watch();

  Future<void> addPhotoRow({
    required String id,
    required String localPath,
    required DateTime takenAt,
    String? pose,
    String? note,
  }) => _db
      .into(_db.progressPhotos)
      .insert(
        ProgressPhotosCompanion.insert(
          id: id,
          localPath: localPath,
          takenAt: takenAt.toUtc(),
          localDate: LocalDates.key(takenAt),
          pose: Value(_blankToNull(pose)),
          note: Value(_blankToNull(note)),
        ),
      );

  Future<void> deletePhotoRow(String id) =>
      (_db.delete(_db.progressPhotos)..where((p) => p.id.equals(id))).go();

  // -------------------------------------------------------------- reports

  Stream<List<Report>> watchReports() => (_db.select(
    _db.reports,
  )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).watch();

  Future<String> saveReport({
    required String kind,
    required String periodStart,
    required String periodEnd,
    required Map<String, Object?> content,
    bool replaceSamePeriod = false,
  }) async {
    final id = newId();
    if (replaceSamePeriod) {
      await (_db.delete(_db.reports)..where(
            (r) =>
                r.kind.equals(kind) &
                r.periodStart.equals(periodStart) &
                r.periodEnd.equals(periodEnd),
          ))
          .go();
    }
    await _db
        .into(_db.reports)
        .insert(
          ReportsCompanion.insert(
            id: id,
            kind: kind,
            periodStart: periodStart,
            periodEnd: periodEnd,
            contentJson: jsonEncode(content),
            createdAt: Value(_nowUtc),
          ),
        );
    return id;
  }

  Future<void> deleteReport(String id) =>
      (_db.delete(_db.reports)..where((r) => r.id.equals(id))).go();

  Future<Report?> weeklyReview(String weekStart) =>
      (_db.select(_db.reports)
            ..where(
              (r) =>
                  r.kind.equals('weekly_review') &
                  r.periodStart.equals(weekStart),
            )
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  // -------------------------------------------------- health restrictions

  Stream<List<HealthRestriction>> watchRestrictions() => (_db.select(
    _db.healthRestrictions,
  )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).watch();

  Future<void> saveRestriction({
    String? id,
    required String description,
    String? bodyPart,
    String? restriction,
    required bool clinicianImposed,
    String? startDate,
    String? endDate,
  }) async {
    final now = _nowUtc;
    if (id == null) {
      await _db
          .into(_db.healthRestrictions)
          .insert(
            HealthRestrictionsCompanion.insert(
              id: newId(),
              description: description.trim(),
              bodyPart: Value(_blankToNull(bodyPart)),
              restriction: Value(_blankToNull(restriction)),
              clinicianImposed: Value(clinicianImposed),
              startDate: Value(startDate),
              endDate: Value(endDate),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    } else {
      await (_db.update(
        _db.healthRestrictions,
      )..where((r) => r.id.equals(id))).write(
        HealthRestrictionsCompanion(
          description: Value(description.trim()),
          bodyPart: Value(_blankToNull(bodyPart)),
          restriction: Value(_blankToNull(restriction)),
          clinicianImposed: Value(clinicianImposed),
          startDate: Value(startDate),
          endDate: Value(endDate),
          updatedAt: Value(now),
        ),
      );
    }
  }

  Future<void> deleteRestriction(String id) =>
      (_db.delete(_db.healthRestrictions)..where((r) => r.id.equals(id))).go();

  // ---------------------------------------------------------- goal history

  /// Read-only view of goal history (written by ProfileRepository.update).
  Stream<List<GoalHistoryData>> watchGoalHistory({int limit = 50}) =>
      (_db.select(_db.goalHistory)
            ..orderBy([(g) => OrderingTerm.desc(g.changedAt)])
            ..limit(limit))
          .watch();

  // ---------------------------------------------------------- day reviews

  Future<Map<String, dynamic>?> dayReview(String date) =>
      _settings.get<Map<String, dynamic>>(PlanningKeys.dayReview(date));

  Future<void> saveDayReview(String date, Map<String, Object?> review) =>
      _settings.set(PlanningKeys.dayReview(date), review);

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}

final planningRepositoryProvider = Provider<PlanningRepository>(
  (ref) => PlanningRepository(
    ref.watch(databaseProvider),
    ref.watch(settingsRepositoryProvider),
    ref.watch(clockProvider),
  ),
);
