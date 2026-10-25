import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/auto_rules.dart';

/// Reads the logged data that automatic habit rules depend on.
class AutoRuleRepository {
  AutoRuleRepository(this._db);
  final AppDatabase _db;

  /// Tables whose changes can flip an automatic completion.
  List<TableInfo<Table, Object?>> get watchedTables => [
    _db.waterLogs,
    _db.dailyHealthSummaries,
    _db.foodLogEntries,
    _db.userProfiles,
  ];

  /// Inputs for every date in [start, end] (inclusive). Goals come from the
  /// current profile.
  Future<Map<String, AutoRuleDay>> daysBetween(String start, String end) async {
    final profile = await (_db.select(
      _db.userProfiles,
    )..where((p) => p.id.equals(1))).getSingleOrNull();
    final waterGoal = profile?.waterGoalMl ?? 0;
    final stepGoal = profile?.stepGoal ?? 0;

    final water = <String, int>{};
    final sumExpr = _db.waterLogs.amountMl.sum();
    final wq = _db.selectOnly(_db.waterLogs)
      ..addColumns([_db.waterLogs.localDate, sumExpr])
      ..where(
        _db.waterLogs.localDate.isBetweenValues(start, end) &
            _db.waterLogs.deletedAt.isNull(),
      )
      ..groupBy([_db.waterLogs.localDate]);
    for (final r in await wq.get()) {
      water[r.read(_db.waterLogs.localDate)!] = r.read(sumExpr) ?? 0;
    }

    // Several origins (health_connect, manual) may exist for a day: use the
    // highest value rather than summing to avoid double counting.
    final steps = <String, double>{};
    final sq = _db.select(_db.dailyHealthSummaries)
      ..where(
        (s) => s.type.equals('steps') & s.localDate.isBetweenValues(start, end),
      );
    for (final s in await sq.get()) {
      final prev = steps[s.localDate];
      if (prev == null || s.value > prev) steps[s.localDate] = s.value;
    }

    final food = <String, int>{};
    final countExpr = _db.foodLogEntries.id.count();
    final fq = _db.selectOnly(_db.foodLogEntries)
      ..addColumns([_db.foodLogEntries.localDate, countExpr])
      ..where(
        _db.foodLogEntries.localDate.isBetweenValues(start, end) &
            _db.foodLogEntries.deletedAt.isNull(),
      )
      ..groupBy([_db.foodLogEntries.localDate]);
    for (final r in await fq.get()) {
      food[r.read(_db.foodLogEntries.localDate)!] = r.read(countExpr) ?? 0;
    }

    return {
      for (final d in LocalDates.range(start, end))
        d: AutoRuleDay(
          waterMl: water[d] ?? 0,
          waterGoalMl: waterGoal,
          steps: steps[d],
          stepGoal: stepGoal,
          foodEntries: food[d] ?? 0,
        ),
    };
  }

  /// Dates in [start, end] on which [rule] is met.
  Future<Set<String>> metDates(AutoRule rule, String start, String end) async {
    final days = await daysBetween(start, end);
    return {
      for (final e in days.entries)
        if (autoRuleMet(rule, e.value)) e.key,
    };
  }
}

final autoRuleRepositoryProvider = Provider<AutoRuleRepository>(
  (ref) => AutoRuleRepository(ref.watch(databaseProvider)),
);
