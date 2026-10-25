/// Mood scales and simple, deterministic statistics. Observations only —
/// nothing here diagnoses anything.
library;

import 'dart:math' as math;

import '../../../core/time/clock.dart';

/// Labels for the 1..5 mood scale.
const moodLabels = <int, String>{
  1: 'Very low',
  2: 'Low',
  3: 'Okay',
  4: 'Good',
  5: 'Great',
};

const energyLabels = <int, String>{
  1: 'Drained',
  2: 'Low',
  3: 'Steady',
  4: 'Energised',
  5: 'Charged',
};

const stressLabels = <int, String>{
  1: 'Calm',
  2: 'Mild',
  3: 'Moderate',
  4: 'High',
  5: 'Very high',
};

const sleepQualityLabels = <int, String>{
  1: 'Very poor',
  2: 'Poor',
  3: 'Fair',
  4: 'Good',
  5: 'Great',
};

const emotionTags = <String>[
  'calm',
  'content',
  'grateful',
  'happy',
  'motivated',
  'focused',
  'proud',
  'energised',
  'tired',
  'restless',
  'anxious',
  'stressed',
  'frustrated',
  'overwhelmed',
  'sad',
  'lonely',
];

/// Minimum paired observations before a correlation coefficient is shown.
const minCorrelationSample = 7;

/// Pearson correlation coefficient, or null when undefined (fewer than two
/// points, mismatched lengths, or zero variance in either series).
double? pearson(List<double> x, List<double> y) {
  if (x.length != y.length || x.length < 2) return null;
  final n = x.length;
  final mx = x.reduce((a, b) => a + b) / n;
  final my = y.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = x[i] - mx;
    final dy = y[i] - my;
    sxy += dx * dy;
    sxx += dx * dx;
    syy += dy * dy;
  }
  if (sxx == 0 || syy == 0) return null;
  return sxy / math.sqrt(sxx * syy);
}

enum CorrelationStatus { notEnoughData, noVariation, ok }

class CorrelationResult {
  const CorrelationResult({
    required this.n,
    required this.status,
    this.r,
    this.meanWith,
    this.meanWithout,
    this.nWith,
    this.nWithout,
  });

  /// Number of paired observations (days).
  final int n;
  final CorrelationStatus status;

  /// Pearson r, only when [status] is ok (n ≥ [minCorrelationSample]).
  final double? r;

  /// For binary comparisons (e.g. workout vs rest days): mean mood per group.
  final double? meanWith;
  final double? meanWithout;
  final int? nWith;
  final int? nWithout;

  bool get hasResult => status == CorrelationStatus.ok && r != null;

  /// "weak positive", "moderate negative", "negligible"...
  String get strengthLabel {
    final v = r;
    if (v == null) return 'not available';
    final a = v.abs();
    final strength = a < 0.1
        ? 'negligible'
        : a < 0.3
        ? 'weak'
        : a < 0.5
        ? 'moderate'
        : 'strong';
    if (strength == 'negligible') return strength;
    return '$strength ${v > 0 ? 'positive' : 'negative'}';
  }
}

/// Correlates paired observations, enforcing the minimum sample size.
CorrelationResult correlate(
  List<(double, double)> pairs, {
  int minN = minCorrelationSample,
}) {
  final n = pairs.length;
  if (n < minN) {
    return CorrelationResult(n: n, status: CorrelationStatus.notEnoughData);
  }
  final r = pearson(
    [for (final p in pairs) p.$1],
    [for (final p in pairs) p.$2],
  );
  if (r == null) {
    return CorrelationResult(n: n, status: CorrelationStatus.noVariation);
  }
  return CorrelationResult(n: n, status: CorrelationStatus.ok, r: r);
}

/// Mood on days with vs without an event (point-biserial correlation).
/// [moodByDay] holds daily mean mood; [eventDays] the days with the event.
CorrelationResult correlateWithEventDays(
  Map<String, double> moodByDay,
  Set<String> eventDays, {
  int minN = minCorrelationSample,
}) {
  final withVals = <double>[];
  final withoutVals = <double>[];
  final pairs = <(double, double)>[];
  final days = moodByDay.keys.toList()..sort();
  for (final d in days) {
    final has = eventDays.contains(d);
    final m = moodByDay[d]!;
    (has ? withVals : withoutVals).add(m);
    pairs.add((has ? 1.0 : 0.0, m));
  }
  double? mean(List<double> v) =>
      v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  final base = correlate(pairs, minN: minN);
  return CorrelationResult(
    n: base.n,
    status: base.status,
    r: base.r,
    meanWith: mean(withVals),
    meanWithout: mean(withoutVals),
    nWith: withVals.length,
    nWithout: withoutVals.length,
  );
}

/// Pairs two per-day series on the days both have values.
List<(double, double)> pairByDay(Map<String, double> a, Map<String, double> b) {
  final days = a.keys.where(b.containsKey).toList()..sort();
  return [for (final d in days) (a[d]!, b[d]!)];
}

/// Minimal mood observation used by the stats helpers.
class MoodPoint {
  const MoodPoint({
    required this.localDate,
    required this.recordedAt,
    required this.mood,
    this.sleepQuality,
  });
  final String localDate;
  final DateTime recordedAt;
  final int mood;
  final int? sleepQuality;
}

/// Mean mood per local date.
Map<String, double> dailyMoodMeans(Iterable<MoodPoint> points) =>
    _dailyMeans(points.map((p) => (p.localDate, p.mood.toDouble())));

/// Mean self-reported sleep quality per local date (entries without one are
/// ignored).
Map<String, double> dailySleepQualityMeans(Iterable<MoodPoint> points) =>
    _dailyMeans(
      points
          .where((p) => p.sleepQuality != null)
          .map((p) => (p.localDate, p.sleepQuality!.toDouble())),
    );

Map<String, double> _dailyMeans(Iterable<(String, double)> values) {
  final sums = <String, double>{};
  final counts = <String, int>{};
  for (final (d, v) in values) {
    sums[d] = (sums[d] ?? 0) + v;
    counts[d] = (counts[d] ?? 0) + 1;
  }
  return {for (final d in sums.keys) d: sums[d]! / counts[d]!};
}

/// Daily means for the [days] days ending at [today] (inclusive), with null
/// for days without an entry, oldest first.
List<(String, double?)> moodTrend(
  Map<String, double> daily,
  String today,
  int days,
) {
  final start = LocalDates.addDays(today, -(days - 1));
  return [for (final d in LocalDates.range(start, today)) (d, daily[d])];
}
