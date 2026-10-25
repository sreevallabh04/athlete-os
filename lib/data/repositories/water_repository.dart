import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/time/clock.dart';
import '../../core/util/ids.dart';
import '../db/database.dart';
import '../providers.dart';

/// Water logging. Shared by the hydration UI, notification actions and the
/// AI `log_water` tool.
class WaterRepository {
  WaterRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  Future<String> add(
    int amountMl, {
    String source = 'manual',
    DateTime? at,
    String? id,
  }) async {
    if (amountMl <= 0 || amountMl > 5000) {
      throw ArgumentError.value(amountMl, 'amountMl', 'must be 1..5000 ml');
    }
    final t = at ?? _clock.now();
    final rowId = id ?? newId();
    await _db
        .into(_db.waterLogs)
        .insert(
          WaterLogsCompanion.insert(
            id: rowId,
            amountMl: amountMl,
            loggedAt: t.toUtc(),
            localDate: LocalDates.key(t),
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return rowId;
  }

  Future<void> remove(String id) =>
      (_db.update(_db.waterLogs)..where((w) => w.id.equals(id))).write(
        WaterLogsCompanion(deletedAt: Value(_clock.now().toUtc())),
      );

  Stream<List<WaterLog>> watchDay(String localDate) =>
      (_db.select(_db.waterLogs)
            ..where((w) => w.localDate.equals(localDate) & w.deletedAt.isNull())
            ..orderBy([(w) => OrderingTerm.desc(w.loggedAt)]))
          .watch();

  Future<List<WaterLog>> day(String localDate) => (_db.select(
    _db.waterLogs,
  )..where((w) => w.localDate.equals(localDate) & w.deletedAt.isNull())).get();

  /// Total ml per day for an inclusive date range (missing days = 0).
  Future<Map<String, int>> totalsByDay(String start, String end) async {
    final rows =
        await (_db.select(_db.waterLogs)..where(
              (w) =>
                  w.localDate.isBetweenValues(start, end) &
                  w.deletedAt.isNull(),
            ))
            .get();
    final out = {for (final d in LocalDates.range(start, end)) d: 0};
    for (final r in rows) {
      out[r.localDate] = (out[r.localDate] ?? 0) + r.amountMl;
    }
    return out;
  }
}

final waterRepositoryProvider = Provider<WaterRepository>(
  (ref) =>
      WaterRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);
