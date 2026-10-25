// Deterministic, AI-free running analytics. Pure functions, unit-tested.
import 'dart:math' as math;

import '../../../core/time/clock.dart';
import 'running_models.dart';

// ---------------------------------------------------------------------------
// Dedupe Strava vs Health Connect
// ---------------------------------------------------------------------------

/// Two records are the same run when they start within ±3 min and their
/// distances agree within ±5%.
bool isSameRun(RunActivity a, RunActivity b) {
  if (a.startAt.difference(b.startAt).abs() > const Duration(minutes: 3)) {
    return false;
  }
  final da = a.distanceM;
  final db = b.distanceM;
  if (da == null || db == null || da <= 0 || db <= 0) return false;
  return (da - db).abs() / math.max(da, db) <= 0.05;
}

/// Hides Health Connect copies of runs that also came from Strava. The Strava
/// record is kept for display and marked [RunActivity.alsoInHealthConnect].
/// Output is sorted newest first.
List<RunActivity> dedupeActivities(List<RunActivity> input) {
  final strava = input.where((a) => a.source == 'strava').toList();
  final hidden = <String>{};
  final dupesFor = <String, List<String>>{};
  for (final a in input) {
    if (a.source != 'health_connect') continue;
    for (final s in strava) {
      if (s.sportType == a.sportType && isSameRun(s, a)) {
        hidden.add(a.id);
        dupesFor.putIfAbsent(s.id, () => []).add(a.id);
        break;
      }
    }
  }
  final out = [
    for (final a in input)
      if (!hidden.contains(a.id))
        dupesFor.containsKey(a.id)
            ? a.copyWith(
                alsoInHealthConnect: true,
                duplicateIds: dupesFor[a.id],
              )
            : a,
  ]..sort((a, b) => b.startAt.compareTo(a.startAt));
  return out;
}

// ---------------------------------------------------------------------------
// Weekly totals, trends and consistency
// ---------------------------------------------------------------------------

class WeekRunning {
  const WeekRunning({
    required this.weekStart,
    required this.distanceM,
    required this.runs,
  });
  final String weekStart;
  final double distanceM;
  final int runs;
}

/// Monday-based weekly distance and run count for runs only (oldest first,
/// empty weeks included).
List<WeekRunning> weeklyRunning(
  List<RunActivity> activities, {
  required String todayKey,
  int weeks = 8,
}) {
  final current = LocalDates.weekStart(todayKey);
  final dist = <String, double>{};
  final count = <String, int>{};
  for (final a in activities.where((a) => a.isRun)) {
    final w = LocalDates.weekStart(a.localDate);
    dist[w] = (dist[w] ?? 0) + (a.distanceM ?? 0);
    count[w] = (count[w] ?? 0) + 1;
  }
  return [
    for (var i = weeks - 1; i >= 0; i--)
      () {
        final s = LocalDates.addDays(current, -7 * i);
        return WeekRunning(
          weekStart: s,
          distanceM: dist[s] ?? 0,
          runs: count[s] ?? 0,
        );
      }(),
  ];
}

class TrendPoint {
  const TrendPoint(this.date, this.value);
  final DateTime date;
  final double value;
}

/// Pace (s/km) per run ≥ 1 km, oldest first.
List<TrendPoint> paceTrend(List<RunActivity> activities, {int limit = 20}) {
  final runs =
      activities
          .where((a) => a.isRun && (a.distanceM ?? 0) >= 1000)
          .where((a) => a.paceSPerKm != null)
          .toList()
        ..sort((a, b) => a.startAt.compareTo(b.startAt));
  final tail = runs.length > limit ? runs.sublist(runs.length - limit) : runs;
  return [for (final r in tail) TrendPoint(r.startAt, r.paceSPerKm!)];
}

/// Distance (m) per run, oldest first.
List<TrendPoint> distanceTrend(List<RunActivity> activities, {int limit = 20}) {
  final runs = activities.where((a) => a.isRun && a.distanceM != null).toList()
    ..sort((a, b) => a.startAt.compareTo(b.startAt));
  final tail = runs.length > limit ? runs.sublist(runs.length - limit) : runs;
  return [for (final r in tail) TrendPoint(r.startAt, r.distanceM!)];
}

/// Least-squares slope of y per point (positive = values going up).
double? linearSlope(List<double> ys) {
  if (ys.length < 2) return null;
  final n = ys.length;
  final mx = (n - 1) / 2;
  final my = ys.reduce((a, b) => a + b) / n;
  var num = 0.0;
  var den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (i - mx) * (ys[i] - my);
    den += (i - mx) * (i - mx);
  }
  return den == 0 ? 0 : num / den;
}

class RunConsistency {
  const RunConsistency({
    required this.weeksWithRuns,
    required this.weeks,
    required this.currentStreakWeeks,
  });
  final int weeksWithRuns;
  final int weeks;

  /// Consecutive weeks (ending this or last week) with ≥1 run.
  final int currentStreakWeeks;
  double get fraction => weeks == 0 ? 0 : weeksWithRuns / weeks;
}

RunConsistency runConsistency(
  List<RunActivity> activities, {
  required String todayKey,
  int weeks = 8,
}) {
  final w = weeklyRunning(activities, todayKey: todayKey, weeks: weeks);
  final withRuns = w.where((x) => x.runs > 0).length;
  var streak = 0;
  // The current week may still be in progress; don't break the streak on it.
  var i = w.length - 1;
  if (i >= 0 && w[i].runs == 0) i--;
  for (; i >= 0; i--) {
    if (w[i].runs > 0) {
      streak++;
    } else {
      break;
    }
  }
  return RunConsistency(
    weeksWithRuns: withRuns,
    weeks: weeks,
    currentStreakWeeks: streak,
  );
}

// ---------------------------------------------------------------------------
// Splits analysis
// ---------------------------------------------------------------------------

/// Splits that are (close to) a full kilometre.
List<RunSplit> fullKmSplits(List<RunSplit> splits) => [
  for (final s in splits)
    if (s.distanceM >= 950 && s.distanceM <= 1050 && s.movingTimeS > 0) s,
];

/// Coefficient of variation (stddev / mean) of full-km split paces.
/// Null with fewer than 3 full splits.
double? splitPaceCv(List<RunSplit> splits) {
  final paces = fullKmSplits(splits).map((s) => s.paceSPerKm!).toList();
  if (paces.length < 3) return null;
  final mean = paces.reduce((a, b) => a + b) / paces.length;
  final variance =
      paces.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) /
      paces.length;
  return mean == 0 ? null : math.sqrt(variance) / mean;
}

enum SplitPattern {
  negative('Negative split'),
  even('Even pacing'),
  positive('Positive split');

  const SplitPattern(this.label);
  final String label;
}

class SplitComparison {
  const SplitComparison(this.pattern, this.firstHalfPace, this.secondHalfPace);
  final SplitPattern pattern;
  final double firstHalfPace;
  final double secondHalfPace;

  /// (second − first) / first; negative = got faster.
  double get changeFraction => (secondHalfPace - firstHalfPace) / firstHalfPace;
}

/// First-half vs second-half pace using full-km splits (needs ≥ 2).
/// Within ±2% counts as even.
SplitComparison? splitComparison(List<RunSplit> splits) {
  final full = fullKmSplits(splits);
  if (full.length < 2) return null;
  final half = full.length ~/ 2;
  final first = full.sublist(0, half);
  final second = full.sublist(full.length - half);
  double pace(List<RunSplit> xs) =>
      xs.fold(0, (a, s) => a + s.movingTimeS) /
      (xs.fold(0.0, (a, s) => a + s.distanceM) / 1000);
  final p1 = pace(first);
  final p2 = pace(second);
  final change = (p2 - p1) / p1;
  final pattern = change < -0.02
      ? SplitPattern.negative
      : change > 0.02
      ? SplitPattern.positive
      : SplitPattern.even;
  return SplitComparison(pattern, p1, p2);
}

class HrDrift {
  const HrDrift(this.firstHalfHr, this.secondHalfHr);
  final double firstHalfHr;
  final double secondHalfHr;
  double get driftFraction => (secondHalfHr - firstHalfHr) / firstHalfHr;
}

/// First vs second half average HR from splits that carry HR (needs ≥ 4).
HrDrift? hrDrift(List<RunSplit> splits) {
  final withHr = splits
      .where((s) => s.avgHr != null && s.avgHr! > 0 && s.distanceM >= 500)
      .toList();
  if (withHr.length < 4) return null;
  final half = withHr.length ~/ 2;
  double avg(Iterable<RunSplit> xs) =>
      xs.map((s) => s.avgHr!).reduce((a, b) => a + b) / xs.length;
  return HrDrift(
    avg(withHr.take(half)),
    avg(withHr.skip(withHr.length - half)),
  );
}

// ---------------------------------------------------------------------------
// Personal bests and goal
// ---------------------------------------------------------------------------

enum Best5kMethod { splits, wholeRun }

class Best5k {
  const Best5k({
    required this.timeS,
    required this.method,
    required this.activityId,
    required this.date,
    required this.label,
  });
  final int timeS;
  final Best5kMethod method;
  final String activityId;
  final DateTime date;

  /// Human-readable provenance, e.g. "Fastest 5 consecutive km splits".
  final String label;
}

/// Best 5 km estimate for a single run:
/// * with splits: fastest 5 consecutive full-km splits (each normalised to
///   exactly 1000 m);
/// * otherwise: the whole run when its distance is 4.9–5.3 km. Runs shorter
///   than 5 km are scaled up to 5 km; longer ones keep their time
///   (conservative).
Best5k? best5kForRun(RunActivity run) {
  if (!run.isRun) return null;
  final full = <RunSplit>[];
  // Consecutive full-km splits only (a short split breaks the sequence).
  int? best;
  for (final s in run.splits) {
    if (s.distanceM >= 950 && s.distanceM <= 1050 && s.movingTimeS > 0) {
      full.add(s);
      if (full.length >= 5) {
        final window = full.sublist(full.length - 5);
        final t = window
            .map((x) => x.movingTimeS * 1000 / x.distanceM)
            .reduce((a, b) => a + b)
            .round();
        if (best == null || t < best) best = t;
      }
    } else {
      full.clear();
    }
  }
  if (best != null) {
    return Best5k(
      timeS: best,
      method: Best5kMethod.splits,
      activityId: run.id,
      date: run.startAt,
      label: 'Fastest 5 consecutive km splits',
    );
  }
  final d = run.distanceM;
  final t = run.timeS;
  if (d != null && t != null && d >= 4900 && d <= 5300) {
    final scaled = d < 5000 ? (t * 5000 / d).round() : t;
    return Best5k(
      timeS: scaled,
      method: Best5kMethod.wholeRun,
      activityId: run.id,
      date: run.startAt,
      label: d < 5000
          ? 'Whole run (${(d / 1000).toStringAsFixed(2)} km, scaled to 5 km)'
          : 'Whole run (${(d / 1000).toStringAsFixed(2)} km)',
    );
  }
  return null;
}

Best5k? best5k(List<RunActivity> runs) {
  Best5k? best;
  for (final r in runs) {
    final b = best5kForRun(r);
    if (b != null && (best == null || b.timeS < best.timeS)) best = b;
  }
  return best;
}

class RunningBests {
  const RunningBests({this.best5k, this.longestRun, this.fastestPaceRun});
  final Best5k? best5k;
  final RunActivity? longestRun;

  /// Fastest average pace among runs of at least 3 km.
  final RunActivity? fastestPaceRun;
}

RunningBests runningBests(List<RunActivity> activities) {
  final runs = activities.where((a) => a.isRun).toList();
  RunActivity? longest;
  RunActivity? fastest;
  for (final r in runs) {
    if (r.distanceM != null &&
        (longest == null || r.distanceM! > longest.distanceM!)) {
      longest = r;
    }
    final p = r.paceSPerKm;
    if (p != null &&
        (r.distanceM ?? 0) >= 3000 &&
        (fastest == null || p < fastest.paceSPerKm!)) {
      fastest = r;
    }
  }
  return RunningBests(
    best5k: best5k(runs),
    longestRun: longest,
    fastestPaceRun: fastest,
  );
}

class GoalProgress {
  const GoalProgress({
    required this.goalTimeS,
    required this.goalDistanceM,
    this.bestTimeS,
  });
  final int goalTimeS;
  final int goalDistanceM;
  final int? bestTimeS;

  bool get hasData => bestTimeS != null;
  bool get achieved => bestTimeS != null && bestTimeS! <= goalTimeS;

  /// Seconds still to cut (0 when achieved).
  int? get gapS =>
      bestTimeS == null ? null : math.max(0, bestTimeS! - goalTimeS);

  /// goal / best, capped at 1.
  double get fraction => bestTimeS == null || bestTimeS! <= 0
      ? 0
      : math.min(1, goalTimeS / bestTimeS!);

  /// Required pace in s/km.
  double get goalPaceSPerKm => goalTimeS / (goalDistanceM / 1000);
}

GoalProgress goalProgress(
  Best5k? best, {
  required int goalTimeS,
  int goalDistanceM = 5000,
}) => GoalProgress(
  goalTimeS: goalTimeS,
  goalDistanceM: goalDistanceM,
  bestTimeS: goalDistanceM == 5000 ? best?.timeS : null,
);
