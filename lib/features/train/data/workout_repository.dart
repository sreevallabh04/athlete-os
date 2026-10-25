import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/strength_models.dart';
import '../domain/workout_draft.dart';

/// Strength workouts (Hevy, CSV, manual) persistence.
class WorkoutRepository {
  WorkoutRepository(this._db);
  final AppDatabase _db;

  /// Inserts or replaces a workout and all of its exercises/sets in one
  /// transaction. Re-importing the same workout is idempotent.
  Future<void> upsertWorkout({
    required String id,
    required String source,
    required WorkoutDraft draft,
    String? externalId,
    String? rawJson,
    DateTime? sourceUpdatedAt,
  }) {
    final now = DateTime.now().toUtc();
    return _db.transaction(() async {
      await _db
          .into(_db.workouts)
          .insertOnConflictUpdate(
            WorkoutsCompanion.insert(
              id: id,
              source: source,
              externalId: Value(externalId),
              title: draft.title.trim().isEmpty
                  ? 'Workout'
                  : draft.title.trim(),
              startAt: draft.startAt.toUtc(),
              endAt: Value(draft.endAt?.toUtc()),
              localDate: LocalDates.key(draft.startAt),
              notes: Value(draft.notes),
              rawJson: Value(rawJson),
              sourceUpdatedAt: Value(sourceUpdatedAt?.toUtc()),
              updatedAt: Value(now),
              deletedAt: const Value(null),
            ),
          );
      await _deleteChildren(id);
      for (var i = 0; i < draft.exercises.length; i++) {
        final e = draft.exercises[i];
        final exId = stableId('workout_exercise', '$id:$i');
        await _db
            .into(_db.workoutExercises)
            .insert(
              WorkoutExercisesCompanion.insert(
                id: exId,
                workoutId: id,
                position: i,
                name: e.name.trim().isEmpty ? 'Exercise' : e.name.trim(),
                templateId: Value(e.templateId),
                muscleGroup: Value(e.muscleGroup),
                notes: Value(e.notes),
                supersetId: Value(e.supersetId),
              ),
            );
        for (var j = 0; j < e.sets.length; j++) {
          final s = e.sets[j];
          await _db
              .into(_db.workoutSets)
              .insert(
                WorkoutSetsCompanion.insert(
                  id: stableId('workout_set', '$exId:$j'),
                  exerciseId: exId,
                  position: j,
                  setType: Value(SetTypes.normalise(s.type)),
                  weightKg: Value(s.weightKg),
                  reps: Value(s.reps),
                  distanceM: Value(s.distanceM),
                  durationS: Value(s.durationS),
                  rpe: Value(s.rpe),
                ),
              );
        }
      }
    });
  }

  Future<void> _deleteChildren(String workoutId) async {
    final exIds =
        await (_db.selectOnly(_db.workoutExercises)
              ..addColumns([_db.workoutExercises.id])
              ..where(_db.workoutExercises.workoutId.equals(workoutId)))
            .map((r) => r.read(_db.workoutExercises.id)!)
            .get();
    if (exIds.isNotEmpty) {
      await (_db.delete(
        _db.workoutSets,
      )..where((s) => s.exerciseId.isIn(exIds))).go();
    }
    await (_db.delete(
      _db.workoutExercises,
    )..where((e) => e.workoutId.equals(workoutId))).go();
  }

  /// Saves a manually logged workout (source `manual`). Returns its id.
  Future<String> saveManual(WorkoutDraft draft, {String? id}) async {
    final wid = id ?? newId();
    await upsertWorkout(id: wid, source: 'manual', draft: draft);
    return wid;
  }

  Future<void> softDelete(String id, {DateTime? at}) =>
      (_db.update(_db.workouts)..where((w) => w.id.equals(id))).write(
        WorkoutsCompanion(
          deletedAt: Value((at ?? DateTime.now()).toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  /// Hard-deletes every workout of [source] (children cascade manually).
  Future<int> deleteBySource(String source) => _db.transaction(() async {
    final ids =
        await (_db.selectOnly(_db.workouts)
              ..addColumns([_db.workouts.id])
              ..where(_db.workouts.source.equals(source)))
            .map((r) => r.read(_db.workouts.id)!)
            .get();
    for (final id in ids) {
      await _deleteChildren(id);
    }
    return (_db.delete(
      _db.workouts,
    )..where((w) => w.source.equals(source))).go();
  });

  /// Sets the muscle group on exercises whose template is now mapped.
  Future<void> applyMuscleMapping(Map<String, String> templateToGroup) async {
    if (templateToGroup.isEmpty) return;
    await _db.transaction(() async {
      for (final e in templateToGroup.entries) {
        await (_db.update(_db.workoutExercises)..where(
              (x) => x.templateId.equals(e.key) & x.muscleGroup.isNull(),
            ))
            .write(WorkoutExercisesCompanion(muscleGroup: Value(e.value)));
      }
    });
  }

  Future<int> countActive({String? source}) async {
    final q = _db.selectOnly(_db.workouts)
      ..addColumns([_db.workouts.id.count()])
      ..where(
        _db.workouts.deletedAt.isNull() &
            (source == null
                ? const Constant(true)
                : _db.workouts.source.equals(source)),
      );
    return (await q.map((r) => r.read(_db.workouts.id.count())).getSingle()) ??
        0;
  }

  /// All non-deleted workouts with exercises and sets, newest first.
  Future<List<WorkoutLog>> loadLogs({DateTime? since}) async {
    final wq = _db.select(_db.workouts)
      ..where(
        (w) =>
            w.deletedAt.isNull() &
            (since == null
                ? const Constant(true)
                : w.startAt.isBiggerOrEqualValue(since.toUtc())),
      )
      ..orderBy([(w) => OrderingTerm.desc(w.startAt)]);
    final workouts = await wq.get();
    if (workouts.isEmpty) return const [];
    final ids = workouts.map((w) => w.id).toList();
    final exercises =
        await (_db.select(_db.workoutExercises)
              ..where((e) => e.workoutId.isIn(ids))
              ..orderBy([(e) => OrderingTerm.asc(e.position)]))
            .get();
    final exIds = exercises.map((e) => e.id).toList();
    final sets = exIds.isEmpty
        ? <WorkoutSet>[]
        : await (_db.select(_db.workoutSets)
                ..where((s) => s.exerciseId.isIn(exIds))
                ..orderBy([(s) => OrderingTerm.asc(s.position)]))
              .get();
    final setsByEx = <String, List<StrengthSet>>{};
    for (final s in sets) {
      setsByEx
          .putIfAbsent(s.exerciseId, () => [])
          .add(
            StrengthSet(
              type: s.setType,
              weightKg: s.weightKg,
              reps: s.reps,
              distanceM: s.distanceM,
              durationS: s.durationS,
              rpe: s.rpe,
            ),
          );
    }
    final exByWorkout = <String, List<ExerciseLog>>{};
    for (final e in exercises) {
      exByWorkout
          .putIfAbsent(e.workoutId, () => [])
          .add(
            ExerciseLog(
              name: e.name,
              templateId: e.templateId,
              muscleGroup: e.muscleGroup,
              notes: e.notes,
              supersetId: e.supersetId,
              sets: setsByEx[e.id] ?? const [],
            ),
          );
    }
    return [
      for (final w in workouts)
        WorkoutLog(
          id: w.id,
          title: w.title,
          startAt: w.startAt,
          endAt: w.endAt,
          localDate: w.localDate,
          source: w.source,
          externalId: w.externalId,
          notes: w.notes,
          exercises: exByWorkout[w.id] ?? const [],
        ),
    ];
  }

  /// Emits [loadLogs] now and after every change to the workout tables.
  Stream<List<WorkoutLog>> watchLogs() async* {
    yield await loadLogs();
    await for (final _ in _db.tableUpdates(
      TableUpdateQuery.onAllTables([
        _db.workouts,
        _db.workoutExercises,
        _db.workoutSets,
      ]),
    )) {
      yield await loadLogs();
    }
  }
}

final workoutRepositoryProvider = Provider<WorkoutRepository>(
  (ref) => WorkoutRepository(ref.watch(databaseProvider)),
);
