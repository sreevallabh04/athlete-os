import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/providers.dart';
import '../../planning/data/metrics_queries.dart';
import '../../planning/data/planning_repository.dart';
import '../data/today_repository.dart';

final todayRepositoryProvider = Provider<TodayRepository>(
  (ref) => TodayRepository(
    ref.watch(databaseProvider),
    ref.watch(planningRepositoryProvider),
    ref.watch(metricsQueriesProvider),
  ),
);

/// Live Today snapshot: reloads whenever any contributing table changes.
final todaySnapshotProvider = StreamProvider<TodaySnapshot>((ref) {
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(todayRepositoryProvider);
  final clock = ref.watch(clockProvider);
  return watchTables(db, repo.watchedTables, () => repo.load(clock.now()));
});
