import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/ids.dart';
import '../db/database.dart';
import '../providers.dart';

/// Reads and updates the single user profile row. Every target change is
/// recorded in [GoalHistory] so goals are never altered silently.
class ProfileRepository {
  ProfileRepository(this._db);
  final AppDatabase _db;

  Stream<UserProfile> watch() => (_db.select(
    _db.userProfiles,
  )..where((p) => p.id.equals(1))).watchSingle();

  Future<UserProfile> get() =>
      (_db.select(_db.userProfiles)..where((p) => p.id.equals(1))).getSingle();

  /// Applies [changes] and logs each changed field to goal history.
  Future<void> update(
    UserProfilesCompanion changes, {
    String changedBy = 'user',
    String? reason,
  }) async {
    await _db.transaction(() async {
      final before = await get();
      await (_db.update(_db.userProfiles)..where((p) => p.id.equals(1))).write(
        changes.copyWith(updatedAt: Value(DateTime.now().toUtc())),
      );
      final after = await get();
      final b = before.toJson();
      final a = after.toJson();
      for (final key in a.keys) {
        if (key == 'updatedAt' || key == 'createdAt') continue;
        if (jsonEncode(a[key]) != jsonEncode(b[key])) {
          await _db
              .into(_db.goalHistory)
              .insert(
                GoalHistoryCompanion.insert(
                  id: newId(),
                  metric: key,
                  oldValue: Value(b[key]?.toString()),
                  newValue: a[key]?.toString() ?? '',
                  changedBy: Value(changedBy),
                  reason: Value(reason),
                ),
              );
        }
      }
    });
  }

  Future<List<GoalHistoryData>> history({int limit = 100}) =>
      (_db.select(_db.goalHistory)
            ..orderBy([(g) => OrderingTerm.desc(g.changedAt)])
            ..limit(limit))
          .get();
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(databaseProvider)),
);

final profileProvider = StreamProvider<UserProfile>(
  (ref) => ref.watch(profileRepositoryProvider).watch(),
);
