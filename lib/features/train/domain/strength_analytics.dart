// Deterministic, AI-free strength analytics. Everything here is pure and
// unit-tested; callers pass already-loaded [WorkoutLog]s.
import 'dart:math' as math;

import '../../../core/time/clock.dart';
import 'strength_models.dart';

/// Estimated one-rep max with the Epley formula. Only defined for 1–12 reps
/// and a positive load; beyond 12 reps the estimate is too unreliable.
double? epley1Rm(double? weightKg, int? reps) {
  if (weightKg == null || reps == null) return null;
  if (weightKg <= 0 || reps < 1 || reps > 12) return null;
  if (reps == 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

/// e1RM of a set, excluding warm-ups.
double? setE1Rm(StrengthSet s) =>
    s.isWarmup ? null : epley1Rm(s.weightKg, s.reps);

class BestSet {
  const BestSet(this.set, this.e1Rm);
  final StrengthSet set;

  /// Null when no set qualified for an e1RM (e.g. all >12 reps).
  final double? e1Rm;
}

/// Best working set of an exercise in one session: highest e1RM, falling back
/// to heaviest weight (then most reps) when no set qualifies for e1RM.
BestSet? bestSet(ExerciseLog exercise) {
  BestSet? best;
  for (final s in exercise.workingSets) {
    final e = setE1Rm(s);
    if (e != null) {
      if (best == null || best.e1Rm == null || e > best.e1Rm!) {
        best = BestSet(s, e);
      }
    } else if (best == null || best.e1Rm == null) {
      final w = s.weightKg ?? 0;
      final bw = best?.set.weightKg ?? -1;
      if (best == null ||
          w > bw ||
          (w == bw && (s.reps ?? 0) > (best.set.reps ?? 0))) {
        best = BestSet(s, null);
      }
    }
  }
  return best;
}

/// Σ weight × reps of non-warm-up sets.
double exerciseVolume(ExerciseLog e) =>
    e.workingSets.fold(0.0, (sum, s) => sum + s.volumeKg);

double sessionVolume(WorkoutLog w) =>
    w.exercises.fold(0.0, (sum, e) => sum + exerciseVolume(e));

int workingSetCount(WorkoutLog w) =>
    w.exercises.fold(0, (sum, e) => sum + e.workingSets.length);

// ---------------------------------------------------------------------------
// Personal records
// ---------------------------------------------------------------------------

enum PrType {
  weight('Heaviest weight'),
  repsAtWeight('Most reps at weight'),
  e1Rm('Estimated 1RM'),
  volume('Exercise volume');

  const PrType(this.label);
  final String label;
}

class PersonalRecord {
  const PersonalRecord({
    required this.workoutId,
    required this.exerciseName,
    required this.type,
    required this.value,
    required this.previous,
    required this.date,
    this.weightKg,
  });

  final String workoutId;
  final String exerciseName;
  final PrType type;

  /// kg for weight/e1RM/volume, reps for repsAtWeight.
  final double value;
  final double previous;
  final DateTime date;

  /// Load for repsAtWeight records.
  final double? weightKg;
}

double _roundLoad(double w) => (w * 2).roundToDouble() / 2;

/// Detects PRs chronologically. The first time an exercise appears only
/// establishes a baseline (no PR), so imports don't flood the UI.
List<PersonalRecord> detectPrs(List<WorkoutLog> workouts) {
  final sorted = [...workouts]..sort((a, b) => a.startAt.compareTo(b.startAt));
  final maxWeight = <String, double>{};
  final maxE1Rm = <String, double>{};
  final maxVolume = <String, double>{};
  final repsAt = <String, Map<double, int>>{};
  final out = <PersonalRecord>[];

  for (final w in sorted) {
    // Merge duplicate exercise entries within a session.
    final byKey = <String, List<ExerciseLog>>{};
    for (final e in w.exercises) {
      byKey.putIfAbsent(e.key, () => []).add(e);
    }
    for (final entry in byKey.entries) {
      final key = entry.key;
      final name = entry.value.first.name;
      final sets = [for (final e in entry.value) ...e.workingSets];
      final seen = maxWeight.containsKey(key) || maxVolume.containsKey(key);

      double? sWeight;
      double? sE1Rm;
      var sVolume = 0.0;
      final sRepsAt = <double, int>{};
      for (final s in sets) {
        final wt = s.weightKg;
        final r = s.reps ?? 0;
        if (wt != null && wt > 0 && r > 0) {
          sWeight = math.max(sWeight ?? 0, wt);
          final k = _roundLoad(wt);
          sRepsAt[k] = math.max(sRepsAt[k] ?? 0, r);
        }
        final e = setE1Rm(s);
        if (e != null) sE1Rm = math.max(sE1Rm ?? 0, e);
        sVolume += s.volumeKg;
      }

      if (seen) {
        void add(PrType t, double v, double prev, {double? wt}) => out.add(
          PersonalRecord(
            workoutId: w.id,
            exerciseName: name,
            type: t,
            value: v,
            previous: prev,
            date: w.startAt,
            weightKg: wt,
          ),
        );
        final pw = maxWeight[key];
        if (sWeight != null && pw != null && pw > 0 && sWeight > pw + 1e-9) {
          add(PrType.weight, sWeight, pw);
        }
        final pe = maxE1Rm[key];
        if (sE1Rm != null && pe != null && sE1Rm > pe + 1e-9) {
          add(PrType.e1Rm, sE1Rm, pe);
        }
        final pv = maxVolume[key];
        if (pv != null && pv > 0 && sVolume > pv + 1e-9) {
          add(PrType.volume, sVolume, pv);
        }
        final prevReps = repsAt[key] ?? const {};
        for (final r in sRepsAt.entries) {
          final p = prevReps[r.key];
          if (p != null && r.value > p) {
            add(
              PrType.repsAtWeight,
              r.value.toDouble(),
              p.toDouble(),
              wt: r.key,
            );
          }
        }
      }

      if (sWeight != null) {
        maxWeight[key] = math.max(maxWeight[key] ?? 0, sWeight);
      } else {
        maxWeight.putIfAbsent(key, () => 0);
      }
      if (sE1Rm != null) maxE1Rm[key] = math.max(maxE1Rm[key] ?? 0, sE1Rm);
      maxVolume[key] = math.max(maxVolume[key] ?? 0, sVolume);
      final m = repsAt.putIfAbsent(key, () => {});
      for (final r in sRepsAt.entries) {
        m[r.key] = math.max(m[r.key] ?? 0, r.value);
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Weekly volume, frequency and muscle groups
// ---------------------------------------------------------------------------

class WeekStrength {
  const WeekStrength({
    required this.weekStart,
    required this.sessions,
    required this.workingSets,
    required this.volumeKg,
  });
  final String weekStart;
  final int sessions;
  final int workingSets;
  final double volumeKg;
}

/// Monday-based weekly totals for the [weeks] weeks ending with the week of
/// [todayKey] (oldest first; empty weeks included).
List<WeekStrength> weeklyStrength(
  List<WorkoutLog> workouts, {
  required String todayKey,
  int weeks = 8,
}) {
  final current = LocalDates.weekStart(todayKey);
  final starts = [
    for (var i = weeks - 1; i >= 0; i--) LocalDates.addDays(current, -7 * i),
  ];
  final byWeek = <String, List<WorkoutLog>>{};
  for (final w in workouts) {
    byWeek.putIfAbsent(LocalDates.weekStart(w.localDate), () => []).add(w);
  }
  return [
    for (final s in starts)
      WeekStrength(
        weekStart: s,
        sessions: byWeek[s]?.length ?? 0,
        workingSets: (byWeek[s] ?? const []).fold(
          0,
          (a, w) => a + workingSetCount(w),
        ),
        volumeKg: (byWeek[s] ?? const []).fold(
          0.0,
          (a, w) => a + sessionVolume(w),
        ),
      ),
  ];
}

class MuscleGroupSets {
  const MuscleGroupSets({
    required this.setsByGroup,
    required this.unmappedSets,
    required this.unmappedExercises,
  });

  /// Working sets per mapped primary muscle group.
  final Map<String, int> setsByGroup;
  final int unmappedSets;
  final Set<String> unmappedExercises;

  int get mappedSets => setsByGroup.values.fold(0, (a, b) => a + b);

  /// Share of working sets that have a muscle mapping (0..1).
  double get mappedFraction {
    final total = mappedSets + unmappedSets;
    return total == 0 ? 0 : mappedSets / total;
  }

  /// Only claim anything about muscle balance when at least 80% of sets are
  /// mapped and there are at least 10 mapped sets.
  bool get sufficientForBalance => mappedSets >= 10 && mappedFraction >= 0.8;
}

MuscleGroupSets muscleGroupSets(Iterable<WorkoutLog> workouts) {
  final sets = <String, int>{};
  var unmapped = 0;
  final unmappedNames = <String>{};
  for (final w in workouts) {
    for (final e in w.exercises) {
      final n = e.workingSets.length;
      if (n == 0) continue;
      final g = e.muscleGroup?.trim();
      if (g == null || g.isEmpty) {
        unmapped += n;
        unmappedNames.add(e.name);
      } else {
        sets[g] = (sets[g] ?? 0) + n;
      }
    }
  }
  return MuscleGroupSets(
    setsByGroup: sets,
    unmappedSets: unmapped,
    unmappedExercises: unmappedNames,
  );
}

// ---------------------------------------------------------------------------
// Per-exercise history and progression
// ---------------------------------------------------------------------------

class ExerciseSessionPoint {
  const ExerciseSessionPoint({
    required this.workoutId,
    required this.date,
    required this.localDate,
    required this.best,
    required this.volumeKg,
    required this.workingSets,
  });
  final String workoutId;
  final DateTime date;
  final String localDate;
  final BestSet? best;
  final double volumeKg;
  final int workingSets;

  double? get e1Rm => best?.e1Rm;
}

class ExerciseHistory {
  const ExerciseHistory({
    required this.key,
    required this.name,
    required this.muscleGroup,
    required this.sessions,
  });
  final String key;
  final String name;
  final String? muscleGroup;

  /// Oldest first.
  final List<ExerciseSessionPoint> sessions;

  double? get bestE1Rm => sessions
      .map((s) => s.e1Rm)
      .whereType<double>()
      .fold<double?>(null, (a, b) => a == null || b > a ? b : a);
}

/// Groups every exercise across [workouts] (oldest session first), sorted by
/// most recently trained.
List<ExerciseHistory> exerciseHistories(List<WorkoutLog> workouts) {
  final sorted = [...workouts]..sort((a, b) => a.startAt.compareTo(b.startAt));
  final map = <String, List<ExerciseSessionPoint>>{};
  final names = <String, String>{};
  final groups = <String, String?>{};
  for (final w in sorted) {
    final byKey = <String, List<ExerciseLog>>{};
    for (final e in w.exercises) {
      byKey.putIfAbsent(e.key, () => []).add(e);
    }
    for (final entry in byKey.entries) {
      final merged = ExerciseLog(
        name: entry.value.first.name,
        sets: [for (final e in entry.value) ...e.sets],
        muscleGroup: entry.value.first.muscleGroup,
      );
      if (merged.workingSets.isEmpty) continue;
      names[entry.key] = merged.name;
      groups[entry.key] = merged.muscleGroup ?? groups[entry.key];
      map
          .putIfAbsent(entry.key, () => [])
          .add(
            ExerciseSessionPoint(
              workoutId: w.id,
              date: w.startAt,
              localDate: w.localDate,
              best: bestSet(merged),
              volumeKg: exerciseVolume(merged),
              workingSets: merged.workingSets.length,
            ),
          );
    }
  }
  final out = [
    for (final e in map.entries)
      ExerciseHistory(
        key: e.key,
        name: names[e.key]!,
        muscleGroup: groups[e.key],
        sessions: e.value,
      ),
  ]..sort((a, b) => b.sessions.last.date.compareTo(a.sessions.last.date));
  return out;
}

enum ProgressionTrend {
  improving('Improving'),
  stable('Stable / stalled'),
  declining('Declining'),
  notEnoughData('Not enough data');

  const ProgressionTrend(this.label);
  final String label;
}

class ProgressionResult {
  const ProgressionResult(
    this.trend, {
    this.slopePctPerSession,
    this.sessions = 0,
  });
  final ProgressionTrend trend;

  /// Least-squares slope of e1RM per session as % of the mean e1RM.
  final double? slopePctPerSession;
  final int sessions;
}

/// Minimum sessions with a valid e1RM before a trend is reported.
const kMinProgressionSessions = 3;

/// ±% of mean e1RM per session separating improving/declining from stable.
const kProgressionThresholdPct = 0.5;

/// e1RM trend over the last [lastN] sessions with a valid e1RM.
ProgressionResult progression(List<double> e1RmsOldestFirst, {int lastN = 6}) {
  final values = e1RmsOldestFirst.length > lastN
      ? e1RmsOldestFirst.sublist(e1RmsOldestFirst.length - lastN)
      : e1RmsOldestFirst;
  if (values.length < kMinProgressionSessions) {
    return ProgressionResult(
      ProgressionTrend.notEnoughData,
      sessions: values.length,
    );
  }
  final n = values.length;
  final meanX = (n - 1) / 2;
  final meanY = values.reduce((a, b) => a + b) / n;
  var num = 0.0;
  var den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (i - meanX) * (values[i] - meanY);
    den += (i - meanX) * (i - meanX);
  }
  final slope = den == 0 ? 0.0 : num / den;
  final pct = meanY == 0 ? 0.0 : slope / meanY * 100;
  final trend = pct >= kProgressionThresholdPct
      ? ProgressionTrend.improving
      : pct <= -kProgressionThresholdPct
      ? ProgressionTrend.declining
      : ProgressionTrend.stable;
  return ProgressionResult(trend, slopePctPerSession: pct, sessions: n);
}

ProgressionResult exerciseProgression(ExerciseHistory h, {int lastN = 6}) =>
    progression(
      h.sessions.map((s) => s.e1Rm).whereType<double>().toList(),
      lastN: lastN,
    );

// ---------------------------------------------------------------------------
// Session comparison
// ---------------------------------------------------------------------------

class ExerciseDelta {
  const ExerciseDelta({
    required this.name,
    this.currentE1Rm,
    this.previousE1Rm,
    required this.currentVolume,
    required this.previousVolume,
  });
  final String name;
  final double? currentE1Rm;
  final double? previousE1Rm;
  final double currentVolume;
  final double previousVolume;

  double? get e1RmDelta => currentE1Rm != null && previousE1Rm != null
      ? currentE1Rm! - previousE1Rm!
      : null;
}

class SessionComparison {
  const SessionComparison({
    required this.current,
    required this.previous,
    required this.exercises,
  });
  final WorkoutLog current;
  final WorkoutLog previous;
  final List<ExerciseDelta> exercises;

  double get volumeDelta => sessionVolume(current) - sessionVolume(previous);
  int get setsDelta => workingSetCount(current) - workingSetCount(previous);
}

/// Compares [current] with the most recent earlier session with the same
/// title (case-insensitive). Null when there is no earlier session.
SessionComparison? compareWithPrevious(
  WorkoutLog current,
  List<WorkoutLog> all,
) {
  final title = exerciseKey(current.title);
  WorkoutLog? prev;
  for (final w in all) {
    if (w.id == current.id) continue;
    if (exerciseKey(w.title) != title) continue;
    if (!w.startAt.isBefore(current.startAt)) continue;
    if (prev == null || w.startAt.isAfter(prev.startAt)) prev = w;
  }
  if (prev == null) return null;
  final prevByKey = {for (final e in prev.exercises) e.key: e};
  final deltas = <ExerciseDelta>[];
  for (final e in current.exercises) {
    final p = prevByKey[e.key];
    deltas.add(
      ExerciseDelta(
        name: e.name,
        currentE1Rm: bestSet(e)?.e1Rm,
        previousE1Rm: p == null ? null : bestSet(p)?.e1Rm,
        currentVolume: exerciseVolume(e),
        previousVolume: p == null ? 0 : exerciseVolume(p),
      ),
    );
  }
  return SessionComparison(current: current, previous: prev, exercises: deltas);
}

/// Distinct training days per local date (for the consistency heatmap).
Map<String, int> sessionsPerDay(Iterable<WorkoutLog> workouts) {
  final out = <String, int>{};
  for (final w in workouts) {
    out[w.localDate] = (out[w.localDate] ?? 0) + 1;
  }
  return out;
}
