import '../../domain/strength_analytics.dart';
import '../../domain/strength_models.dart';

/// Recent personal records, newest first, one per workout + exercise (the
/// e1RM record wins over top-set, rep and volume records of the same lift).
List<PersonalRecord> recentPrs(List<WorkoutLog> workouts, {int max = 8}) {
  const rank = {
    PrType.e1Rm: 0,
    PrType.weight: 1,
    PrType.repsAtWeight: 2,
    PrType.volume: 3,
  };
  final best = <String, PersonalRecord>{};
  for (final p in detectPrs(workouts)) {
    final k = '${p.workoutId}|${exerciseKey(p.exerciseName)}';
    final cur = best[k];
    if (cur == null || rank[p.type]! < rank[cur.type]!) best[k] = p;
  }
  final list = best.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  return list.take(max).toList();
}
