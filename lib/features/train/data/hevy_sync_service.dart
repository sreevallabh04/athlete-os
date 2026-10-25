import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../integrations/data/api_errors.dart';
import '../../integrations/data/secret_store.dart';
import '../domain/strength_models.dart';
import '../domain/workout_draft.dart';
import 'hevy_api_client.dart';
import 'workout_repository.dart';

/// Settings key holding `{fetched_at, map: {templateId: primaryMuscleGroup}}`.
const kHevyTemplatesSettingKey = 'hevy_exercise_templates';

class HevySyncResult {
  const HevySyncResult({
    required this.upserted,
    required this.deleted,
    required this.fullImport,
  });
  final int upserted;
  final int deleted;
  final bool fullImport;
}

typedef HevyApiFactory = HevyApi Function(String apiKey);

/// Converts a Hevy workout JSON object to a [WorkoutDraft].
WorkoutDraft hevyWorkoutToDraft(
  Map<String, dynamic> w, {
  Map<String, String> muscleMap = const {},
}) {
  DateTime? t(Object? v) => DateTime.tryParse(v?.toString() ?? '');
  final exercises = <ExerciseDraft>[];
  final rawExercises = (w['exercises'] as List?) ?? const [];
  final sortedEx = rawExercises.whereType<Map<String, dynamic>>().toList()
    ..sort(
      (a, b) =>
          ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0),
    );
  for (final e in sortedEx) {
    final sets =
        ((e['sets'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList()
          ..sort(
            (a, b) => ((a['index'] as num?) ?? 0).compareTo(
              (b['index'] as num?) ?? 0,
            ),
          );
    final templateId = e['exercise_template_id']?.toString();
    exercises.add(
      ExerciseDraft(
        name: (e['title'] ?? 'Exercise').toString(),
        templateId: templateId,
        muscleGroup: templateId == null ? null : muscleMap[templateId],
        notes: (e['notes'] as String?)?.trim().isEmpty ?? true
            ? null
            : e['notes'] as String,
        supersetId: (e['superset_id'] as num?)?.toInt(),
        sets: [
          for (final s in sets)
            SetDraft(
              type: SetTypes.normalise(s['type']?.toString()),
              weightKg: (s['weight_kg'] as num?)?.toDouble(),
              reps: (s['reps'] as num?)?.round(),
              distanceM: (s['distance_meters'] as num?)?.toDouble(),
              durationS: (s['duration_seconds'] as num?)?.round(),
              rpe: (s['rpe'] as num?)?.toDouble(),
            ),
        ],
      ),
    );
  }
  final start = t(w['start_time']) ?? t(w['created_at']) ?? DateTime.now();
  final desc = (w['description'] as String?)?.trim();
  return WorkoutDraft(
    title: (w['title'] ?? 'Workout').toString(),
    startAt: start,
    endAt: t(w['end_time']),
    notes: desc == null || desc.isEmpty ? null : desc,
    exercises: exercises,
  );
}

/// Hevy connection, import and incremental sync.
class HevySyncService {
  HevySyncService({
    required this._db,
    required this._workouts,
    required this._status,
    required this._settings,
    required this._secrets,
    required this._apiFactory,
    required this._clock,
  });

  final AppDatabase _db;
  final WorkoutRepository _workouts;
  final IntegrationStatusRepository _status;
  final SettingsRepository _settings;
  final SecretStore _secrets;
  final HevyApiFactory _apiFactory;
  final Clock _clock;

  static const _maxPages = 2000;

  Future<bool> hasKey() async =>
      ((await _secrets.read(SecretKeys.hevyApiKey)) ?? '').isNotEmpty;

  /// Validates [apiKey] with `/v1/user/info`. Only on success is the key
  /// stored and the integration marked connected.
  Future<void> connect(String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw InvalidCredentialsException('Enter your Hevy API key');
    }
    final api = _apiFactory(key);
    try {
      final info = await api.userInfo();
      await _secrets.write(SecretKeys.hevyApiKey, key);
      final data = info['data'] is Map ? info['data'] as Map : info;
      await _status.setStatus(
        Providers.hevy,
        ConnectionStates.connected,
        scopes: const ['read:workouts', 'read:exercise_templates'],
        meta: {if (data['name'] != null) 'username': data['name'].toString()},
      );
    } on InvalidCredentialsException {
      await _status.setStatus(
        Providers.hevy,
        ConnectionStates.error,
        error: 'Invalid API key',
      );
      rethrow;
    } on IntegrationException catch (e) {
      await _status.setStatus(
        Providers.hevy,
        ConnectionStates.error,
        error: e.message,
      );
      rethrow;
    }
  }

  /// Re-runs the connection test with the stored key.
  Future<void> testConnection() async {
    final key = await _secrets.read(SecretKeys.hevyApiKey);
    if (key == null || key.isEmpty) {
      throw InvalidCredentialsException('No Hevy API key saved');
    }
    await connect(key);
  }

  /// Removes the key. Imported workouts are deleted only if [deleteData].
  Future<void> disconnect({required bool deleteData}) async {
    await _secrets.delete(SecretKeys.hevyApiKey);
    if (deleteData) await _workouts.deleteBySource('hevy');
    await _status.setStatus(
      Providers.hevy,
      ConnectionStates.disconnected,
      scopes: const [],
      clearError: true,
    );
    await _clearCursor();
  }

  Future<void> _clearCursor() =>
      (_db.update(_db.integrationConnections)
            ..where((c) => c.provider.equals(Providers.hevy)))
          .write(const IntegrationConnectionsCompanion(cursor: Value(null)));

  /// Full import on first run, then incremental via workout events.
  Future<HevySyncResult> sync() async {
    final key = await _secrets.read(SecretKeys.hevyApiKey);
    if (key == null || key.isEmpty) {
      throw InvalidCredentialsException('No Hevy API key saved');
    }
    final api = _apiFactory(key);
    try {
      final muscleMap = await _templates(api);
      final row = await _status.get(Providers.hevy);
      final cursor = DateTime.tryParse(row?.cursor ?? '');
      final result = cursor == null
          ? await _fullImport(api, muscleMap)
          : await _incremental(api, cursor, muscleMap);
      return result;
    } on InvalidCredentialsException {
      await _status.setStatus(
        Providers.hevy,
        ConnectionStates.error,
        error: 'Invalid API key',
      );
      rethrow;
    } on IntegrationException catch (e) {
      await _status.recordSync(Providers.hevy, error: e.message);
      rethrow;
    }
  }

  Future<HevySyncResult> _fullImport(
    HevyApi api,
    Map<String, String> muscleMap,
  ) async {
    DateTime? newest;
    var upserted = 0;
    for (var page = 1; page <= _maxPages; page++) {
      final res = await api.workouts(page: page, pageSize: 10);
      for (final w in res.items) {
        final updated = await _upsert(w, muscleMap);
        if (updated != null && (newest == null || updated.isAfter(newest))) {
          newest = updated;
        }
        upserted++;
      }
      if (!res.hasMore || res.items.isEmpty) break;
    }
    await _status.recordSync(
      Providers.hevy,
      cursor: (newest ?? _clock.now()).toUtc().toIso8601String(),
    );
    return HevySyncResult(upserted: upserted, deleted: 0, fullImport: true);
  }

  Future<HevySyncResult> _incremental(
    HevyApi api,
    DateTime since,
    Map<String, String> muscleMap,
  ) async {
    var newest = since;
    var upserted = 0;
    var deleted = 0;
    for (var page = 1; page <= _maxPages; page++) {
      final res = await api.workoutEvents(
        since: since,
        page: page,
        pageSize: 10,
      );
      for (final e in res.items) {
        switch (e) {
          case HevyUpdatedEvent(:final workout):
            final u = await _upsert(workout, muscleMap);
            if (u != null && u.isAfter(newest)) newest = u;
            upserted++;
          case HevyDeletedEvent(:final id, :final deletedAt):
            await _workouts.softDelete(
              stableId('hevy', id),
              at: deletedAt ?? _clock.now(),
            );
            if (deletedAt != null && deletedAt.isAfter(newest)) {
              newest = deletedAt;
            }
            deleted++;
        }
      }
      if (!res.hasMore || res.items.isEmpty) break;
    }
    await _status.recordSync(
      Providers.hevy,
      cursor: newest.toUtc().toIso8601String(),
    );
    return HevySyncResult(
      upserted: upserted,
      deleted: deleted,
      fullImport: false,
    );
  }

  /// Returns the workout's `updated_at`.
  Future<DateTime?> _upsert(
    Map<String, dynamic> w,
    Map<String, String> muscleMap,
  ) async {
    final id = w['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final updated = DateTime.tryParse(w['updated_at']?.toString() ?? '');
    await _workouts.upsertWorkout(
      id: stableId('hevy', id),
      source: 'hevy',
      externalId: id,
      draft: hevyWorkoutToDraft(w, muscleMap: muscleMap),
      rawJson: jsonEncode(w),
      sourceUpdatedAt: updated,
    );
    return updated;
  }

  /// Exercise templates (for primary muscle group mapping), refreshed at
  /// most weekly. Failures here never block workout sync.
  Future<Map<String, String>> _templates(HevyApi api) async {
    final cached = await _settings.get<Map<String, dynamic>>(
      kHevyTemplatesSettingKey,
    );
    final fetchedAt = DateTime.tryParse(cached?['fetched_at'] as String? ?? '');
    final map = <String, String>{
      for (final e in ((cached?['map'] as Map?) ?? const {}).entries)
        e.key.toString(): e.value.toString(),
    };
    final now = _clock.now();
    if (fetchedAt != null &&
        now.difference(fetchedAt) < const Duration(days: 7)) {
      return map;
    }
    try {
      final fresh = <String, String>{};
      for (var page = 1; page <= 100; page++) {
        final res = await api.exerciseTemplates(page: page, pageSize: 100);
        for (final t in res.items) {
          final id = t['id']?.toString();
          final g = t['primary_muscle_group']?.toString();
          if (id != null && g != null && g.isNotEmpty && g != 'other') {
            fresh[id] = g;
          }
        }
        if (!res.hasMore || res.items.isEmpty) break;
      }
      await _settings.set(kHevyTemplatesSettingKey, {
        'fetched_at': now.toUtc().toIso8601String(),
        'map': fresh,
      });
      await _workouts.applyMuscleMapping(fresh);
      return fresh;
    } on InvalidCredentialsException {
      rethrow;
    } on IntegrationException {
      return map;
    }
  }
}

final hevyApiFactoryProvider = Provider<HevyApiFactory>(
  (ref) =>
      (key) => HttpHevyApi(key),
);

final hevySyncServiceProvider = Provider<HevySyncService>(
  (ref) => HevySyncService(
    db: ref.watch(databaseProvider),
    workouts: ref.watch(workoutRepositoryProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    secrets: ref.watch(secretStoreProvider),
    apiFactory: ref.watch(hevyApiFactoryProvider),
    clock: ref.watch(clockProvider),
  ),
);
