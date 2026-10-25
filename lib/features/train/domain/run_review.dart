// Rule-based post-run review. No AI is involved: this is what is shown for
// Strava activities, whose data may never be sent to an AI (Strava API
// Policy §5.3). Every rule is deterministic and unit-tested.
import 'dart:math' as math;

import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import 'running_analytics.dart';
import 'running_models.dart';

const kReviewLabel = 'Automated analysis (rule-based, no AI)';

/// Maximum week-over-week running volume increase a suggestion may cause.
const kMaxWeeklyIncrease = 0.10;

enum NextWorkoutType {
  rest('Rest or cross-train'),
  easy('Easy run'),
  steady('Steady run'),
  strides('Easy run + strides'),
  long('Easy long run');

  const NextWorkoutType(this.label);
  final String label;
}

class NextWorkout {
  const NextWorkout({
    required this.type,
    required this.distanceKm,
    required this.description,
    required this.rationale,
  });
  final NextWorkoutType type;

  /// 0 for rest days.
  final double distanceKm;
  final String description;
  final String rationale;
}

class SimilarRunsComparison {
  const SimilarRunsComparison({
    required this.count,
    required this.avgPaceSPerKm,
    required this.paceDeltaFraction,
  });
  final int count;
  final double avgPaceSPerKm;

  /// (this − avg) / avg; negative = faster than usual.
  final double paceDeltaFraction;
}

class RunReview {
  const RunReview({
    required this.summary,
    required this.paceConsistency,
    required this.paceCv,
    required this.splitComparison,
    required this.hrDrift,
    required this.similar,
    required this.hardEffort,
    required this.next,
    required this.takeaway,
    required this.uncertainty,
  });
  final String summary;
  final String? paceConsistency;
  final double? paceCv;
  final SplitComparison? splitComparison;
  final HrDrift? hrDrift;
  final SimilarRunsComparison? similar;
  final bool hardEffort;
  final NextWorkout next;
  final String takeaway;
  final String uncertainty;
}

/// Runs within ±20% distance of [run], before it, newest first (max 5).
List<RunActivity> similarRuns(RunActivity run, List<RunActivity> history) {
  final d = run.distanceM;
  if (d == null || d <= 0) return const [];
  final out =
      history
          .where(
            (h) =>
                h.id != run.id &&
                h.isRun &&
                h.startAt.isBefore(run.startAt) &&
                h.paceSPerKm != null &&
                h.distanceM != null &&
                (h.distanceM! - d).abs() / d <= 0.20,
          )
          .toList()
        ..sort((a, b) => b.startAt.compareTo(a.startAt));
  return out.take(5).toList();
}

/// Weekly running distance (m) of the Monday-week containing [dateKey].
double weekDistance(List<RunActivity> runs, String dateKey) {
  final w = LocalDates.weekStart(dateKey);
  return runs
      .where((r) => r.isRun && LocalDates.weekStart(r.localDate) == w)
      .fold(0.0, (a, r) => a + (r.distanceM ?? 0));
}

/// Builds the review for [run]. [history] contains the user's other
/// (deduplicated) activities; [todayKey] anchors the weekly volume cap.
RunReview reviewRun(
  RunActivity run,
  List<RunActivity> history, {
  required String todayKey,
}) {
  final distKm = (run.distanceM ?? 0) / 1000;
  final pace = run.paceSPerKm;
  final cv = splitPaceCv(run.splits);
  final split = splitComparison(run.splits);
  final drift = hrDrift(run.splits);
  final similar = similarRuns(run, history);

  SimilarRunsComparison? sim;
  if (similar.isNotEmpty && pace != null) {
    final avg =
        similar.map((s) => s.paceSPerKm!).reduce((a, b) => a + b) /
        similar.length;
    sim = SimilarRunsComparison(
      count: similar.length,
      avgPaceSPerKm: avg,
      paceDeltaFraction: (pace - avg) / avg,
    );
  }

  // Summary
  final parts = <String>[
    if (distKm > 0) '${distKm.toStringAsFixed(2)} km',
    if (run.timeS != null) 'in ${Fmt.duration(run.timeS!)}',
    if (pace != null) 'at ${Fmt.pace(pace)}',
    if (run.avgHr != null) 'avg HR ${run.avgHr!.round()} bpm',
  ];
  final summary = parts.isEmpty
      ? 'Not enough data recorded to summarise this run.'
      : '${parts.join(' ')}.';

  String? consistency;
  if (cv != null) {
    final pct = (cv * 100).toStringAsFixed(1);
    consistency = cv < 0.03
        ? 'Very even pacing (split variation $pct%).'
        : cv < 0.06
        ? 'Fairly consistent pacing (split variation $pct%).'
        : 'Uneven pacing (split variation $pct%) — hills, stops or surges '
              'can all cause this.';
  }

  // Effort heuristics: faster than usual for this distance, or notable
  // cardiac drift, or a strongly positive split.
  final hard =
      (sim != null && sim.paceDeltaFraction <= -0.03) ||
      (drift != null && drift.driftFraction >= 0.05) ||
      (split != null && split.changeFraction >= 0.06);

  // Recent trend: are the last 3 runs (incl. this) slower than the 3 before?
  final recent = [
    run,
    ...history.where(
      (h) =>
          h.isRun &&
          h.id != run.id &&
          h.paceSPerKm != null &&
          h.startAt.isBefore(run.startAt),
    ),
  ]..sort((a, b) => b.startAt.compareTo(a.startAt));
  var negativeTrend = false;
  if (recent.length >= 6 && recent.take(6).every((r) => r.paceSPerKm != null)) {
    double avg(Iterable<RunActivity> xs) =>
        xs.map((x) => x.paceSPerKm!).reduce((a, b) => a + b) / xs.length;
    negativeTrend = avg(recent.take(3)) > avg(recent.skip(3).take(3)) * 1.03;
  }

  final next = suggestNextWorkout(
    run: run,
    history: history,
    todayKey: todayKey,
    hardEffort: hard,
    negativeTrend: negativeTrend,
  );

  // One takeaway, most important first.
  final String takeaway;
  if (drift != null && drift.driftFraction >= 0.05) {
    takeaway =
        'Heart rate rose ${(drift.driftFraction * 100).toStringAsFixed(0)}% '
        'from the first to the second half — keep easy runs genuinely easy '
        'to build aerobic base.';
  } else if (split?.pattern == SplitPattern.negative) {
    takeaway =
        'Nice negative split — finishing faster is a great habit for '
        'racing a 5K.';
  } else if (split?.pattern == SplitPattern.positive) {
    takeaway =
        'You slowed in the second half. Try starting ~5–10 s/km '
        'slower next time.';
  } else if (sim != null && sim.paceDeltaFraction <= -0.03) {
    takeaway =
        'Faster than your recent runs of similar distance — recover '
        'well before the next quality session.';
  } else if (cv != null && cv < 0.03) {
    takeaway = 'Even pacing — good control.';
  } else {
    takeaway = 'Consistency beats intensity: keep stacking regular runs.';
  }

  final uncertainty =
      'Rule-based estimate. It does not account for weather, terrain, GPS '
      'quality, or sleep and recovery'
      '${run.splits.isEmpty ? '; no per-km splits were available' : ''}'
      '${drift == null ? '; heart-rate drift could not be assessed' : ''}.';

  return RunReview(
    summary: summary,
    paceConsistency: consistency,
    paceCv: cv,
    splitComparison: split,
    hrDrift: drift,
    similar: sim,
    hardEffort: hard,
    next: next,
    takeaway: takeaway,
    uncertainty: uncertainty,
  );
}

/// Conservative next-workout rule. Never suggests a distance that would take
/// this week above last week's volume × 1.10 (when last week had volume).
NextWorkout suggestNextWorkout({
  required RunActivity run,
  required List<RunActivity> history,
  required String todayKey,
  required bool hardEffort,
  required bool negativeTrend,
}) {
  final all = {
    for (final r in [...history, run]) r.id: r,
  }.values.toList();
  final thisWeek = weekDistance(all, todayKey) / 1000;
  final lastWeek =
      weekDistance(
        all,
        LocalDates.addDays(LocalDates.weekStart(todayKey), -7),
      ) /
      1000;
  final runKm = (run.distanceM ?? 0) / 1000;

  // Weekly cap. Without a baseline week, limit to this run's distance and
  // at most 5 km so we never jump volume blindly.
  final double cap;
  if (lastWeek > 0) {
    cap = math.max(0, lastWeek * (1 + kMaxWeeklyIncrease) - thisWeek);
  } else {
    cap = math.min(runKm > 0 ? runKm : 3, 5);
  }

  NextWorkout make(NextWorkoutType t, double desired, String desc, String why) {
    final km = (math.min(desired, cap) * 10).floorToDouble() / 10;
    if (km < 2) {
      return NextWorkout(
        type: NextWorkoutType.rest,
        distanceKm: 0,
        description: 'Rest, walk or cross-train (strength, mobility).',
        rationale: lastWeek > 0
            ? 'Another run this week would exceed a 10% increase over last '
                  'week (${lastWeek.toStringAsFixed(1)} km).'
            : 'Keep total volume conservative until you have a baseline week.',
      );
    }
    return NextWorkout(
      type: t,
      distanceKm: km,
      description: '$desc — ${km.toStringAsFixed(1)} km',
      rationale: why,
    );
  }

  if (hardEffort || negativeTrend) {
    return make(
      NextWorkoutType.easy,
      math.max(runKm * 0.8, 3),
      'Easy, conversational pace',
      hardEffort
          ? 'This was a hard effort; an easy run aids recovery.'
          : 'Recent runs trend slower — prioritise recovery.',
    );
  }
  final recentRuns = history.where((h) => h.isRun).length;
  if (recentRuns < 3) {
    return make(
      NextWorkoutType.easy,
      math.max(runKm, 3),
      'Easy run at a comfortable pace',
      'Building a base first: a few more easy runs give better data.',
    );
  }
  return make(
    NextWorkoutType.strides,
    math.max(runKm, 3),
    'Easy run finishing with 4–6 × 20 s relaxed strides',
    'Good recent consistency; strides add speed without much fatigue.',
  );
}
