/// Storage-independent metric records and pure statistics used by the
/// competition review, reports and Today. Every function here is
/// deterministic and unit-tested.
library;

import '../../../core/time/clock.dart' show LocalDates;

/// Logged nutrition totals for one day.
class DayNutrition {
  const DayNutrition({
    required this.date,
    this.kcal = 0,
    this.proteinG = 0,
    this.carbsG = 0,
    this.fatG = 0,
    this.entries = 0,
  });

  final String date;
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final int entries;

  bool get logged => entries > 0;
}

class WeightPoint {
  const WeightPoint({
    required this.date,
    required this.at,
    required this.kg,
    required this.origin,
  });
  final String date;
  final DateTime at;
  final double kg;
  final String origin;
}

/// A per-day aggregate (steps, sleep minutes...) with its origin.
class DailyMetric {
  const DailyMetric({
    required this.date,
    required this.value,
    required this.origin,
    this.computedAt,
    this.sourcesSummary,
  });
  final String date;
  final double value;
  final String origin;
  final DateTime? computedAt;
  final String? sourcesSummary;
}

class CardioRecord {
  const CardioRecord({
    required this.date,
    required this.sportType,
    required this.source,
    required this.startAt,
    this.distanceM,
    this.movingTimeS,
    this.name,
  });
  final String date;
  final String sportType;
  final String source;
  final DateTime startAt;
  final double? distanceM;
  final int? movingTimeS;
  final String? name;

  bool get isRun => sportType == 'run';
}

class WorkoutRecord {
  const WorkoutRecord({
    required this.id,
    required this.title,
    required this.date,
    required this.source,
    required this.startAt,
  });
  final String id;
  final String title;
  final String date;
  final String source;
  final DateTime startAt;
}

class StrengthSet {
  const StrengthSet({
    required this.workoutId,
    required this.date,
    required this.exercise,
    this.setType = 'normal',
    this.weightKg,
    this.reps,
  });
  final String workoutId;
  final String date;
  final String exercise;
  final String setType;
  final double? weightKg;
  final int? reps;

  bool get isWarmup => setType == 'warmup';

  /// weight × reps for working sets; 0 for warm-ups or incomplete sets.
  double get volume =>
      (isWarmup || weightKg == null || reps == null) ? 0 : weightKg! * reps!;
}

class MoodPoint {
  const MoodPoint({required this.date, required this.mood, this.energy});
  final String date;
  final int mood;
  final int? energy;
}

class SeriesPoint {
  const SeriesPoint(this.date, this.value);
  final String date;
  final double value;

  Map<String, Object?> toJson() => {'d': date, 'v': value};
  static SeriesPoint fromJson(Map<String, Object?> j) =>
      SeriesPoint(j['d']! as String, (j['v']! as num).toDouble());
}

/// When both Health Connect and manual rows exist for the same day, Health
/// Connect wins (it is deduplicated across devices); manual fills gaps.
Map<String, DailyMetric> preferHealthConnect(Iterable<DailyMetric> rows) {
  final out = <String, DailyMetric>{};
  for (final r in rows) {
    final existing = out[r.date];
    if (existing == null ||
        (existing.origin != 'health_connect' && r.origin == 'health_connect')) {
      out[r.date] = r;
    }
  }
  return out;
}

/// Nutrition adherence over [dates] (only logged days can count as hits).
class NutritionAdherence {
  const NutritionAdherence({
    required this.totalDays,
    required this.loggedDays,
    required this.proteinDays,
    required this.calorieDays,
    required this.bothDays,
  });
  final int totalDays;
  final int loggedDays;

  /// Logged days with protein ≥ target.
  final int proteinDays;

  /// Logged days with calories within ±10% of target.
  final int calorieDays;
  final int bothDays;
}

bool withinTenPercent(double kcal, int target) =>
    target > 0 && (kcal - target).abs() <= target * 0.10;

NutritionAdherence nutritionAdherence(
  Map<String, DayNutrition> days,
  List<String> dates, {
  required int calorieTarget,
  required double proteinTargetG,
}) {
  var logged = 0, protein = 0, kcal = 0, both = 0;
  for (final d in dates) {
    final n = days[d];
    if (n == null || !n.logged) continue;
    logged++;
    final p = n.proteinG >= proteinTargetG;
    final c = withinTenPercent(n.kcal, calorieTarget);
    if (p) protein++;
    if (c) kcal++;
    if (p && c) both++;
  }
  return NutritionAdherence(
    totalDays: dates.length,
    loggedDays: logged,
    proteinDays: protein,
    calorieDays: kcal,
    bothDays: both,
  );
}

/// Mean of each day's readings, ordered by date.
List<SeriesPoint> dailyMeans(Iterable<WeightPoint> points) {
  final byDay = <String, List<double>>{};
  for (final p in points) {
    byDay.putIfAbsent(p.date, () => []).add(p.kg);
  }
  final keys = byDay.keys.toList()..sort();
  return [
    for (final k in keys)
      SeriesPoint(k, byDay[k]!.reduce((a, b) => a + b) / byDay[k]!.length),
  ];
}

/// Trailing moving average over a calendar-day [window] (default 7): for each
/// day with a reading, the mean of daily means within the preceding
/// [window] calendar days (inclusive). Days without readings are skipped,
/// never interpolated.
List<SeriesPoint> trailingMovingAverage(
  Iterable<WeightPoint> points, {
  int window = 7,
}) {
  final daily = dailyMeans(points);
  final out = <SeriesPoint>[];
  for (var i = 0; i < daily.length; i++) {
    final from = LocalDates.addDays(daily[i].date, -(window - 1));
    final inWindow = daily
        .sublist(0, i + 1)
        .where((p) => p.date.compareTo(from) >= 0)
        .map((p) => p.value)
        .toList();
    out.add(
      SeriesPoint(
        daily[i].date,
        inWindow.reduce((a, b) => a + b) / inWindow.length,
      ),
    );
  }
  return out;
}

/// Monday-start week keys for the [weeks] weeks ending with the week of
/// [endDate] (oldest first).
List<String> weekStarts(String endDate, int weeks) {
  final last = LocalDates.weekStart(endDate);
  return [
    for (var i = weeks - 1; i >= 0; i--) LocalDates.addDays(last, -7 * i),
  ];
}

/// Sums [value] of [items] into Monday-start weeks (missing weeks = 0).
Map<String, double> weeklyTotals<T>(
  Iterable<T> items, {
  required String Function(T) date,
  required double Function(T) value,
  required List<String> weeks,
}) {
  final out = {for (final w in weeks) w: 0.0};
  for (final it in items) {
    final w = LocalDates.weekStart(date(it));
    if (out.containsKey(w)) out[w] = out[w]! + value(it);
  }
  return out;
}

/// Running summary: only `run` activities count; walks/rides are excluded so
/// pace and distance are never mixed across sports.
class RunSummary {
  const RunSummary({
    required this.count,
    required this.distanceM,
    required this.sources,
    required this.excludedNonRuns,
    this.avgPaceSecPerKm,
  });
  final int count;
  final double distanceM;

  /// Total moving time / total distance over runs that have both values.
  final double? avgPaceSecPerKm;
  final Set<String> sources;
  final int excludedNonRuns;
}

RunSummary summarizeRuns(Iterable<CardioRecord> activities) {
  final runs = activities.where((a) => a.isRun).toList();
  var dist = 0.0, pacedDist = 0.0, pacedTime = 0;
  for (final r in runs) {
    final d = r.distanceM;
    if (d != null && d > 0) {
      dist += d;
      final t = r.movingTimeS;
      if (t != null && t > 0) {
        pacedDist += d;
        pacedTime += t;
      }
    }
  }
  return RunSummary(
    count: runs.length,
    distanceM: dist,
    avgPaceSecPerKm: pacedDist > 0 ? pacedTime / (pacedDist / 1000) : null,
    sources: runs.map((r) => r.source).toSet(),
    excludedNonRuns: activities.length - runs.length,
  );
}

/// Total working volume (kg) — warm-up sets are excluded.
double totalVolume(Iterable<StrengthSet> sets) =>
    sets.fold(0.0, (sum, s) => sum + s.volume);

class ExerciseProgress {
  const ExerciseProgress({
    required this.exercise,
    required this.firstDate,
    required this.lastDate,
    required this.firstTopKg,
    required this.lastTopKg,
    required this.sessions,
  });
  final String exercise;
  final String firstDate;
  final String lastDate;
  final double firstTopKg;
  final double lastTopKg;
  final int sessions;
  double get deltaKg => lastTopKg - firstTopKg;
}

/// The exercise with the largest top-set weight increase between its first
/// and last session in the data (working sets only). Null when no exercise
/// was performed in at least two sessions.
ExerciseProgress? topExerciseProgress(Iterable<StrengthSet> sets) {
  // exercise -> workoutId -> (date, top weight)
  final sessions = <String, Map<String, (String, double)>>{};
  for (final s in sets) {
    if (s.isWarmup || s.weightKg == null) continue;
    final perWorkout = sessions.putIfAbsent(s.exercise, () => {});
    final prev = perWorkout[s.workoutId];
    if (prev == null || s.weightKg! > prev.$2) {
      perWorkout[s.workoutId] = (s.date, s.weightKg!);
    }
  }
  ExerciseProgress? best;
  final names = sessions.keys.toList()..sort();
  for (final name in names) {
    final list = sessions[name]!.values.toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    if (list.length < 2) continue;
    final p = ExerciseProgress(
      exercise: name,
      firstDate: list.first.$1,
      lastDate: list.last.$1,
      firstTopKg: list.first.$2,
      lastTopKg: list.last.$2,
      sessions: list.length,
    );
    if (best == null || p.deltaKg > best.deltaKg) best = p;
  }
  return best;
}

double? mean(Iterable<num> values) {
  if (values.isEmpty) return null;
  return values.fold<double>(0, (a, b) => a + b) / values.length;
}

/// Human label for an origin/source key.
String sourceLabel(String key) => switch (key) {
  'health_connect' => 'Health Connect',
  'manual' => 'Manual',
  'hevy' => 'Hevy',
  'strava' => 'Strava',
  'csv' => 'CSV import',
  'notification' => 'Notification',
  'ai' => 'AI coach',
  'openfoodfacts' || 'open_food_facts' => 'Open Food Facts',
  'usda' => 'USDA',
  'custom' => 'Custom food',
  'quick_add' => 'Quick add',
  'ai_estimate' => 'AI estimate',
  _ => key,
};

String sourcesLabel(Iterable<String> keys) {
  final labels = keys.map(sourceLabel).toSet().toList()..sort();
  return labels.isEmpty ? 'No source' : labels.join(' + ');
}
