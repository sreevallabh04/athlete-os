import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/mood_stats.dart';

class MoodInput {
  const MoodInput({
    required this.mood,
    this.energy,
    this.stress,
    this.sleepQuality,
    this.tags = const [],
    this.note,
  });
  final int mood;
  final int? energy;
  final int? stress;
  final int? sleepQuality;
  final List<String> tags;
  final String? note;
}

List<String> moodTagsOf(MoodEntry e) {
  try {
    final v = jsonDecode(e.emotionTagsJson);
    return v is List ? v.whereType<String>().toList() : const [];
  } catch (_) {
    return const [];
  }
}

MoodPoint moodPointOf(MoodEntry e) => MoodPoint(
  localDate: e.localDate,
  recordedAt: e.recordedAt,
  mood: e.mood,
  sleepQuality: e.sleepQuality,
);

/// Mood check-ins. Sensitive: never logged or sent anywhere from here.
class MoodRepository {
  MoodRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  int? _scale(int? v) => v?.clamp(1, 5);

  Future<String> add(MoodInput input) async {
    final now = _clock.now();
    final id = newId();
    final note = input.note?.trim();
    await _db
        .into(_db.moodEntries)
        .insert(
          MoodEntriesCompanion.insert(
            id: id,
            localDate: LocalDates.key(now),
            recordedAt: now.toUtc(),
            mood: input.mood.clamp(1, 5),
            energy: Value(_scale(input.energy)),
            stress: Value(_scale(input.stress)),
            sleepQuality: Value(_scale(input.sleepQuality)),
            emotionTagsJson: Value(jsonEncode(input.tags)),
            note: Value(note == null || note.isEmpty ? null : note),
            createdAt: Value(now.toUtc()),
            updatedAt: Value(now.toUtc()),
          ),
        );
    return id;
  }

  Future<void> delete(String id) =>
      (_db.update(_db.moodEntries)..where((m) => m.id.equals(id))).write(
        MoodEntriesCompanion(
          deletedAt: Value(_clock.now().toUtc()),
          updatedAt: Value(_clock.now().toUtc()),
        ),
      );

  /// Entries between two local dates (inclusive), newest first.
  Stream<List<MoodEntry>> watchRange(String start, String end) =>
      (_db.select(_db.moodEntries)
            ..where(
              (m) =>
                  m.deletedAt.isNull() &
                  m.localDate.isBetweenValues(start, end),
            )
            ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)]))
          .watch();

  Future<List<MoodEntry>> range(String start, String end) =>
      (_db.select(_db.moodEntries)
            ..where(
              (m) =>
                  m.deletedAt.isNull() &
                  m.localDate.isBetweenValues(start, end),
            )
            ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)]))
          .get();

  /// Latest check-in on a date, or null.
  Stream<MoodEntry?> watchLatestOn(String localDate) =>
      (_db.select(_db.moodEntries)
            ..where((m) => m.deletedAt.isNull() & m.localDate.equals(localDate))
            ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)])
            ..limit(1))
          .watchSingleOrNull();

  /// Self-reported or synced sleep minutes per day, if present.
  Future<Map<String, double>> sleepMinutesBetween(
    String start,
    String end,
  ) async {
    final rows =
        await (_db.select(_db.dailyHealthSummaries)..where(
              (s) =>
                  s.type.equals('sleep_minutes') &
                  s.localDate.isBetweenValues(start, end),
            ))
            .get();
    final out = <String, double>{};
    for (final r in rows) {
      final prev = out[r.localDate];
      if (prev == null || r.value > prev) out[r.localDate] = r.value;
    }
    return out;
  }

  /// Local dates with at least one logged (non-deleted) workout.
  Future<Set<String>> workoutDaysBetween(String start, String end) async {
    final rows =
        await (_db.selectOnly(_db.workouts, distinct: true)
              ..addColumns([_db.workouts.localDate])
              ..where(
                _db.workouts.deletedAt.isNull() &
                    _db.workouts.localDate.isBetweenValues(start, end),
              ))
            .get();
    return {for (final r in rows) r.read(_db.workouts.localDate)!};
  }
}

final moodRepositoryProvider = Provider<MoodRepository>(
  (ref) =>
      MoodRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);
