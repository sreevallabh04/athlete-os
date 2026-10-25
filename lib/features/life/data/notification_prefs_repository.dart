import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/reminder_kinds.dart';

/// Reminder preferences per kind (all disabled until the user opts in).
class NotificationPrefsRepository {
  NotificationPrefsRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  Map<ReminderKind, ReminderPref> _toPrefs(List<NotificationPref> rows) {
    final byKey = {for (final r in rows) r.kind: r};
    return {
      for (final k in ReminderKind.values)
        k: ReminderPref(
          kind: k,
          enabled: byKey[k.key]?.enabled ?? false,
          config: ReminderConfig.parse(byKey[k.key]?.configJson, k.defaults),
        ),
    };
  }

  Stream<Map<ReminderKind, ReminderPref>> watchAll() =>
      _db.select(_db.notificationPrefs).watch().map(_toPrefs);

  Future<Map<ReminderKind, ReminderPref>> all() async =>
      _toPrefs(await _db.select(_db.notificationPrefs).get());

  Future<void> save(
    ReminderKind kind, {
    bool? enabled,
    ReminderConfig? config,
  }) async {
    final current = (await all())[kind]!;
    await _db
        .into(_db.notificationPrefs)
        .insertOnConflictUpdate(
          NotificationPrefsCompanion.insert(
            kind: kind.key,
            enabled: Value(enabled ?? current.enabled),
            configJson: Value((config ?? current.config).encode()),
            updatedAt: Value(_clock.now().toUtc()),
          ),
        );
  }
}

final notificationPrefsRepositoryProvider =
    Provider<NotificationPrefsRepository>(
      (ref) => NotificationPrefsRepository(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
      ),
    );

final notificationPrefsProvider =
    StreamProvider<Map<ReminderKind, ReminderPref>>(
      (ref) => ref.watch(notificationPrefsRepositoryProvider).watchAll(),
    );
