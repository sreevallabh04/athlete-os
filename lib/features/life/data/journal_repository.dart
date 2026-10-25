import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';

/// Journal entries. Stored only on this device; never logged. Sending text
/// to AI is gated elsewhere by `SettingKeys.aiJournalConsent`.
class JournalRepository {
  JournalRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  Stream<List<JournalEntry>> watchAll() =>
      (_db.select(_db.journalEntries)
            ..where((j) => j.deletedAt.isNull())
            ..orderBy([
              (j) => OrderingTerm.desc(j.localDate),
              (j) => OrderingTerm.desc(j.createdAt),
            ]))
          .watch();

  Future<List<JournalEntry>> all() =>
      (_db.select(_db.journalEntries)
            ..where((j) => j.deletedAt.isNull())
            ..orderBy([(j) => OrderingTerm.desc(j.localDate)]))
          .get();

  Future<JournalEntry?> get(String id) => (_db.select(
    _db.journalEntries,
  )..where((j) => j.id.equals(id) & j.deletedAt.isNull())).getSingleOrNull();

  /// Whether a non-empty entry exists for [localDate].
  Stream<bool> watchHasEntryOn(String localDate) =>
      (_db.select(_db.journalEntries)..where(
            (j) =>
                j.deletedAt.isNull() &
                j.localDate.equals(localDate) &
                (j.body.length.isBiggerThanValue(0) | j.gratitude.isNotNull()),
          ))
          .watch()
          .map((rows) => rows.isNotEmpty);

  /// Creates or updates an entry (autosave). Returns the entry id.
  Future<String> save({
    String? id,
    required String localDate,
    required String body,
    String? gratitude,
    String? prompt,
  }) async {
    final now = _clock.now().toUtc();
    final g = gratitude?.trim();
    final rowId = id ?? newId();
    await _db
        .into(_db.journalEntries)
        .insertOnConflictUpdate(
          JournalEntriesCompanion.insert(
            id: rowId,
            localDate: localDate,
            body: Value(body),
            gratitude: Value(g == null || g.isEmpty ? null : g),
            prompt: Value(prompt),
            updatedAt: Value(now),
            createdAt: id == null ? Value(now) : const Value.absent(),
          ),
        );
    return rowId;
  }

  Future<void> softDelete(String id) =>
      (_db.update(_db.journalEntries)..where((j) => j.id.equals(id))).write(
        JournalEntriesCompanion(
          deletedAt: Value(_clock.now().toUtc()),
          updatedAt: Value(_clock.now().toUtc()),
        ),
      );
}

final journalRepositoryProvider = Provider<JournalRepository>(
  (ref) =>
      JournalRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);
