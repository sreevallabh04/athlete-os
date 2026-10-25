import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/redact.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/csv.dart';
import 'photo_storage.dart';

/// Per-dataset CSV exports. Journal is only exported when explicitly chosen.
enum ExportDataset {
  foodLog('Food log'),
  water('Water'),
  steps('Steps & daily activity'),
  workoutSets('Workout sets'),
  runs('Runs & cardio'),
  habits('Habit check-ins'),
  mood('Mood'),
  journal('Journal (private)');

  const ExportDataset(this.label);
  final String label;
}

/// Data categories the user can delete from Privacy & data.
enum DeleteCategory {
  journal('Journal entries'),
  mood('Mood check-ins'),
  progressPhotos('Progress photos (files and records)'),
  aiData('AI conversations, memory and activity log'),
  nutrition('Nutrition logs (food and water)'),
  everything('Everything on this device');

  const DeleteCategory(this.label);
  final String label;
}

class DataExportService {
  DataExportService(this._db, this._photos, this._clock);
  final AppDatabase _db;
  final PhotoStorage _photos;
  final Clock _clock;

  static const _serializer = ValueSerializer.defaults(
    serializeDateTimeValuesAsString: true,
  );

  /// JSON of every user table (progress photos as metadata only — image
  /// files are never included). Internal sync bookkeeping is excluded.
  Future<String> exportAllJson() async {
    final tables = <String, Object?>{};
    for (final table in _db.allTables) {
      final name = table.actualTableName;
      if (name == _db.syncQueue.actualTableName) continue;
      final rows = await _db.select(table).get();
      tables[name] = [
        for (final r in rows)
          if (r is DataClass) _clean(name, r.toJson(serializer: _serializer)),
      ];
    }
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'Athlete OS',
      'exportedAt': _clock.now().toUtc().toIso8601String(),
      'format': 'athlete_os.export.v1',
      'notes': [
        'Progress photo image files are not included; only their metadata.',
        'Data imported from Strava, Hevy and Health Connect remains subject '
            "to those services' terms.",
      ],
      'tables': tables,
    });
  }

  Map<String, dynamic> _clean(String table, Map<String, dynamic> row) {
    if (table == _db.appSettings.actualTableName ||
        table == _db.integrationConnections.actualTableName) {
      return row.map((k, v) => MapEntry(k, v is String ? redactSecrets(v) : v));
    }
    return row;
  }

  Future<String> exportCsv(ExportDataset ds, String start, String end) async {
    switch (ds) {
      case ExportDataset.foodLog:
        final rows =
            await (_db.select(_db.foodLogEntries)
                  ..where(
                    (f) =>
                        f.localDate.isBetweenValues(start, end) &
                        f.deletedAt.isNull(),
                  )
                  ..orderBy([(f) => OrderingTerm.asc(f.loggedAt)]))
                .get();
        return toCsv(
          [
            'date',
            'logged_at_utc',
            'meal',
            'name',
            'brand',
            'servings',
            'grams',
            'kcal',
            'protein_g',
            'carbs_g',
            'fat_g',
            'fiber_g',
            'source',
            'verification',
          ],
          rows.map(
            (r) => [
              r.localDate,
              r.loggedAt,
              r.mealType,
              r.name,
              r.brand,
              r.servings,
              r.grams,
              r.calories,
              r.proteinG,
              r.carbsG,
              r.fatG,
              r.fiberG,
              r.source,
              r.verification,
            ],
          ),
        );
      case ExportDataset.water:
        final rows =
            await (_db.select(_db.waterLogs)
                  ..where(
                    (w) =>
                        w.localDate.isBetweenValues(start, end) &
                        w.deletedAt.isNull(),
                  )
                  ..orderBy([(w) => OrderingTerm.asc(w.loggedAt)]))
                .get();
        return toCsv([
          'date',
          'logged_at_utc',
          'amount_ml',
          'source',
        ], rows.map((r) => [r.localDate, r.loggedAt, r.amountMl, r.source]));
      case ExportDataset.steps:
        final rows =
            await (_db.select(_db.dailyHealthSummaries)
                  ..where((s) => s.localDate.isBetweenValues(start, end))
                  ..orderBy([
                    (s) => OrderingTerm.asc(s.localDate),
                    (s) => OrderingTerm.asc(s.type),
                  ]))
                .get();
        return toCsv(
          ['date', 'type', 'value', 'unit', 'origin', 'sources'],
          rows.map(
            (r) => [
              r.localDate,
              r.type,
              r.value,
              r.unit,
              r.origin,
              r.sourcesSummary,
            ],
          ),
        );
      case ExportDataset.workoutSets:
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
              ])
              ..where(
                _db.workouts.localDate.isBetweenValues(start, end) &
                    _db.workouts.deletedAt.isNull(),
              )
              ..orderBy([
                OrderingTerm.asc(_db.workouts.startAt),
                OrderingTerm.asc(_db.workoutExercises.position),
                OrderingTerm.asc(_db.workoutSets.position),
              ]);
        final rows = await q.get();
        return toCsv(
          [
            'date',
            'workout',
            'source',
            'exercise',
            'set',
            'set_type',
            'weight_kg',
            'reps',
            'distance_m',
            'duration_s',
            'rpe',
          ],
          rows.map((row) {
            final w = row.readTable(_db.workouts);
            final e = row.readTable(_db.workoutExercises);
            final s = row.readTable(_db.workoutSets);
            return [
              w.localDate,
              w.title,
              w.source,
              e.name,
              s.position + 1,
              s.setType,
              s.weightKg,
              s.reps,
              s.distanceM,
              s.durationS,
              s.rpe,
            ];
          }),
        );
      case ExportDataset.runs:
        final rows =
            await (_db.select(_db.cardioActivities)
                  ..where(
                    (c) =>
                        c.localDate.isBetweenValues(start, end) &
                        c.deletedAt.isNull(),
                  )
                  ..orderBy([(c) => OrderingTerm.asc(c.startAt)]))
                .get();
        return toCsv(
          [
            'date',
            'start_utc',
            'sport',
            'name',
            'distance_m',
            'moving_time_s',
            'elapsed_time_s',
            'elevation_gain_m',
            'avg_hr',
            'source',
          ],
          rows.map(
            (r) => [
              r.localDate,
              r.startAt,
              r.sportType,
              r.name,
              r.distanceM,
              r.movingTimeS,
              r.elapsedTimeS,
              r.elevationGainM,
              r.avgHeartRate,
              r.source,
            ],
          ),
        );
      case ExportDataset.habits:
        final q =
            _db.select(_db.habitCompletions).join([
                innerJoin(
                  _db.habits,
                  _db.habits.id.equalsExp(_db.habitCompletions.habitId),
                ),
              ])
              ..where(
                _db.habitCompletions.localDate.isBetweenValues(start, end),
              )
              ..orderBy([OrderingTerm.asc(_db.habitCompletions.localDate)]);
        final rows = await q.get();
        return toCsv(
          ['date', 'habit', 'category', 'status', 'note'],
          rows.map((row) {
            final h = row.readTable(_db.habits);
            final c = row.readTable(_db.habitCompletions);
            return [c.localDate, h.name, h.category, c.status, c.note];
          }),
        );
      case ExportDataset.mood:
        final rows =
            await (_db.select(_db.moodEntries)
                  ..where(
                    (m) =>
                        m.localDate.isBetweenValues(start, end) &
                        m.deletedAt.isNull(),
                  )
                  ..orderBy([(m) => OrderingTerm.asc(m.recordedAt)]))
                .get();
        return toCsv(
          [
            'date',
            'recorded_at_utc',
            'mood',
            'energy',
            'stress',
            'sleep_quality',
            'tags',
            'note',
          ],
          rows.map(
            (r) => [
              r.localDate,
              r.recordedAt,
              r.mood,
              r.energy,
              r.stress,
              r.sleepQuality,
              r.emotionTagsJson,
              r.note,
            ],
          ),
        );
      case ExportDataset.journal:
        final rows =
            await (_db.select(_db.journalEntries)
                  ..where(
                    (j) =>
                        j.localDate.isBetweenValues(start, end) &
                        j.deletedAt.isNull(),
                  )
                  ..orderBy([(j) => OrderingTerm.asc(j.localDate)]))
                .get();
        return toCsv([
          'date',
          'prompt',
          'body',
          'gratitude',
        ], rows.map((r) => [r.localDate, r.prompt, r.body, r.gratitude]));
    }
  }

  /// Permanently deletes a category of data from this device.
  Future<void> deleteCategory(DeleteCategory c) async {
    switch (c) {
      case DeleteCategory.journal:
        await _db.delete(_db.journalEntries).go();
      case DeleteCategory.mood:
        await _db.delete(_db.moodEntries).go();
      case DeleteCategory.progressPhotos:
        await _photos.deleteAll();
        await _db.delete(_db.progressPhotos).go();
      case DeleteCategory.aiData:
        await _db.transaction(() async {
          await _db.delete(_db.aiMessages).go();
          await _db.delete(_db.aiConversations).go();
          await _db.delete(_db.aiMemories).go();
          await _db.delete(_db.aiToolActions).go();
          await _db.delete(_db.aiRecommendations).go();
        });
      case DeleteCategory.nutrition:
        await _db.transaction(() async {
          await _db.delete(_db.foodLogEntries).go();
          await _db.delete(_db.waterLogs).go();
        });
      case DeleteCategory.everything:
        await _photos.deleteAll();
        await _db.transaction(() async {
          // Children before parents so foreign keys are never violated.
          for (final t in _db.allTables.toList().reversed) {
            await _db.delete(t).go();
          }
          await _db
              .into(_db.userProfiles)
              .insert(const UserProfilesCompanion());
        });
    }
  }
}

final dataExportServiceProvider = Provider<DataExportService>(
  (ref) => DataExportService(
    ref.watch(databaseProvider),
    ref.watch(photoStorageProvider),
    ref.watch(clockProvider),
  ),
);
