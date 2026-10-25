/// Pure step-coach maths. No Flutter, no I/O — safe to call from the
/// notifications engine, AI tools and widgets alike.
library;

import 'dart:math' as math;

const _minutesPerDay = 24 * 60;

/// Progress of [steps] towards [goal].
class StepsProgress {
  const StepsProgress({
    required this.steps,
    required this.goal,
    required this.remaining,
    required this.fraction,
  });

  final int steps;
  final int goal;

  /// `max(0, goal - steps)`; 0 when there is no goal.
  final int remaining;

  /// 0..n (may exceed 1.0 when over goal). 0 when there is no goal.
  final double fraction;

  bool get hasGoal => goal > 0;
  bool get goalMet => hasGoal && steps >= goal;

  /// Whole percent, e.g. 87 or 124.
  int get percent => (fraction * 100).floor();
}

StepsProgress stepsProgress(int steps, int goal) {
  final s = math.max(0, steps);
  if (goal <= 0) {
    return StepsProgress(steps: s, goal: 0, remaining: 0, fraction: 0);
  }
  return StepsProgress(
    steps: s,
    goal: goal,
    remaining: math.max(0, goal - s),
    fraction: s / goal,
  );
}

/// The user's waking window, in minutes after local midnight. Supports
/// overnight schedules (e.g. wake 22:00, sleep 06:00).
class WakingWindow {
  const WakingWindow({required this.wakeMinutes, required this.sleepMinutes});

  final int wakeMinutes;
  final int sleepMinutes;

  int get _wake => wakeMinutes % _minutesPerDay;
  int get _sleep => sleepMinutes % _minutesPerDay;

  bool get isOvernight => _sleep < _wake;

  /// Length of the waking day in minutes (a full day if wake == sleep).
  int get lengthMinutes {
    final len = (_sleep - _wake) % _minutesPerDay;
    return len == 0 ? _minutesPerDay : len;
  }

  static int _minuteOfDay(DateTime now) => now.hour * 60 + now.minute;

  bool isAwake(DateTime now) {
    final m = _minuteOfDay(now);
    if (_wake == _sleep) return true;
    return isOvernight
        ? (m >= _wake || m < _sleep)
        : (m >= _wake && m < _sleep);
  }

  /// True before today's wake time on a normal (same-day) schedule.
  bool isBeforeWake(DateTime now) =>
      !isOvernight && _wake != _sleep && _minuteOfDay(now) < _wake;

  /// Waking minutes left in the current waking period.
  /// * Awake: minutes until bedtime.
  /// * Before wake time (same-day schedule): the whole waking day is ahead.
  /// * After bedtime: 0.
  int remainingMinutes(DateTime now) {
    final m = _minuteOfDay(now);
    if (isAwake(now)) {
      if (_wake == _sleep) return _minutesPerDay - m;
      return (_sleep - m) % _minutesPerDay;
    }
    if (isBeforeWake(now)) return lengthMinutes;
    return 0;
  }

  /// Fraction (0..1) of the waking day already elapsed. Before wake time it
  /// is 0; after bedtime (or between an overnight schedule's sleep and wake)
  /// it is 1.
  double elapsedFraction(DateTime now) {
    if (isAwake(now)) {
      final elapsed = lengthMinutes - remainingMinutes(now);
      return (elapsed / lengthMinutes).clamp(0.0, 1.0);
    }
    return isBeforeWake(now) ? 0.0 : 1.0;
  }
}

/// Steps needed per remaining waking hour to reach the goal. Returns null
/// when no goal is set, the goal is already met or the waking day is over.
/// This is an *estimate* and must be labelled as such in the UI.
double? stepsPerRemainingHour({
  required int steps,
  required int goal,
  required DateTime now,
  required WakingWindow window,
}) {
  final p = stepsProgress(steps, goal);
  if (!p.hasGoal || p.goalMet) return null;
  final minutes = window.remainingMinutes(now);
  if (minutes <= 0) return null;
  // Never divide by less than 15 minutes: avoids absurd numbers right
  // before bedtime.
  final hours = math.max(minutes, 15) / 60;
  return p.remaining / hours;
}

/// Result of a behind-pace check.
class PaceCheck {
  const PaceCheck({
    required this.expectedByNow,
    required this.steps,
    required this.behind,
  });

  /// goal × fraction of waking day elapsed.
  final int expectedByNow;
  final int steps;
  final bool behind;

  /// steps / expected (1.0 when nothing is expected yet).
  double get ratio => expectedByNow <= 0 ? 1.0 : steps / expectedByNow;
}

/// Behind-pace detection for an optional, gentle nudge.
///
/// Expected steps by now = goal × fraction of the waking day elapsed.
/// The user is "behind" when steps < [threshold] (default 70%) of expected.
/// Never behind when there is no goal, the goal is met, before wake time,
/// after bedtime, or within [graceMinutes] of waking up.
PaceCheck checkPace({
  required int steps,
  required int goal,
  required DateTime now,
  required WakingWindow window,
  double threshold = 0.7,
  int graceMinutes = 60,
}) {
  final p = stepsProgress(steps, goal);
  final fraction = window.elapsedFraction(now);
  final expected = (p.goal * fraction).round();
  final awake = window.isAwake(now);
  final minutesAwake = window.lengthMinutes - window.remainingMinutes(now);
  final eligible =
      p.hasGoal && !p.goalMet && awake && minutesAwake >= graceMinutes;
  return PaceCheck(
    expectedByNow: expected,
    steps: p.steps,
    behind: eligible && expected > 0 && p.steps < threshold * expected,
  );
}

/// Aggregate statistics over a set of days.
class StepsStats {
  const StepsStats({
    required this.days,
    required this.daysWithData,
    required this.average,
    required this.goalHitDays,
    required this.total,
  });

  final int days;
  final int daysWithData;

  /// Mean over days that have data (null when none).
  final double? average;
  final int goalHitDays;
  final int total;
}

/// Statistics for the given per-day step counts. Days mapped to null
/// (no data) are excluded from the average rather than counted as zero.
StepsStats stepsStats(Map<String, int?> byDay, int goal) {
  final values = byDay.values.whereType<int>().toList();
  final total = values.fold<int>(0, (a, b) => a + b);
  return StepsStats(
    days: byDay.length,
    daysWithData: values.length,
    average: values.isEmpty ? null : total / values.length,
    goalHitDays: goal <= 0 ? 0 : values.where((v) => v >= goal).length,
    total: total,
  );
}

/// The step count shown for one day after combining Health Connect and
/// manual values.
class DaySteps {
  const DaySteps({
    required this.steps,
    required this.origin,
    this.overriddenManual,
    this.sourcesSummary,
    this.computedAt,
  });

  final int steps;

  /// 'health_connect' | 'manual'
  final String origin;

  /// A manual value that exists for the day but is superseded by Health
  /// Connect data (shown as secondary).
  final int? overriddenManual;
  final String? sourcesSummary;
  final DateTime? computedAt;

  bool get isManual => origin == 'manual';
}

/// Precedence rule: a Health Connect value wins over a manual value for the
/// same day (it is measured and deduplicated by Health Connect); the manual
/// value is kept and shown as overridden. With only a manual value, the
/// manual value is used. Returns null when neither exists.
DaySteps? resolveDaySteps({
  int? healthConnect,
  int? manual,
  String? hcSourcesSummary,
  DateTime? hcComputedAt,
  DateTime? manualComputedAt,
}) {
  if (healthConnect != null) {
    return DaySteps(
      steps: healthConnect,
      origin: 'health_connect',
      overriddenManual: manual,
      sourcesSummary: hcSourcesSummary,
      computedAt: hcComputedAt,
    );
  }
  if (manual != null) {
    return DaySteps(
      steps: manual,
      origin: 'manual',
      computedAt: manualComputedAt,
    );
  }
  return null;
}
