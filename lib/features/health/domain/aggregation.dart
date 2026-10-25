/// Pure aggregation and de-duplication rules for Health Connect records.
///
/// Dedupe rules (documented in docs/integrations/health-connect.md):
/// 1. Records are first de-duplicated by Health Connect uuid.
/// 2. Steps use Health Connect's aggregate API (it already resolves phone +
///    watch overlap using the user's app-priority list).
/// 3. Distance and active calories: per local day, ONE source app is used —
///    the app with the largest total that day. Records from other apps are
///    ignored (listed in the summary as "also seen"). Within that app,
///    overlapping records are pro-rated so overlapping time is counted once.
/// 4. Sleep: per night (local date of the session END), one source app (the
///    one with the most sleep that night) and overlapping sessions from that
///    app are merged.
/// 5. Active minutes: union of all exercise-session intervals (any source),
///    so overlapping sessions are counted once, split at local midnight.
/// 6. Heart rate: at most one stored sample per 5-minute bucket (the latest
///    actual reading from the source with the most readings in the bucket).
library;

import 'dart:math' as math;

import '../../../core/time/clock.dart';
import 'health_types.dart';
import 'sources.dart';

/// A closed-open time interval.
class TimeInterval {
  const TimeInterval(this.start, this.end);
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);

  @override
  bool operator ==(Object other) =>
      other is TimeInterval && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimeInterval($start → $end)';
}

/// Removes records with a duplicate uuid (keeps the first). Records with an
/// empty uuid are kept.
List<HcRecord> dedupeByUuid(Iterable<HcRecord> records) {
  final seen = <String>{};
  final out = <HcRecord>[];
  for (final r in records) {
    if (r.uuid.isEmpty || seen.add('${r.type.name}:${r.uuid}')) out.add(r);
  }
  return out;
}

/// Merges overlapping/adjacent intervals. Zero/negative-length intervals are
/// dropped.
List<TimeInterval> mergeIntervals(Iterable<TimeInterval> intervals) {
  final sorted = intervals.where((i) => i.end.isAfter(i.start)).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final out = <TimeInterval>[];
  for (final i in sorted) {
    if (out.isNotEmpty && !i.start.isAfter(out.last.end)) {
      final last = out.removeLast();
      out.add(
        TimeInterval(last.start, i.end.isAfter(last.end) ? i.end : last.end),
      );
    } else {
      out.add(i);
    }
  }
  return out;
}

/// Splits intervals at local midnight and returns whole minutes per
/// local date (rounded per day).
Map<String, int> minutesPerLocalDay(Iterable<TimeInterval> intervals) {
  final secondsByDay = <String, int>{};
  for (final i in mergeIntervals(intervals)) {
    var cursor = i.start.toLocal();
    final end = i.end.toLocal();
    while (cursor.isBefore(end)) {
      final key = LocalDates.key(cursor);
      final (_, nextMidnight) = LocalDates.bounds(key);
      final segEnd = nextMidnight.isBefore(end) ? nextMidnight : end;
      secondsByDay[key] =
          (secondsByDay[key] ?? 0) + segEnd.difference(cursor).inSeconds;
      cursor = segEnd;
    }
  }
  return secondsByDay.map((k, s) => MapEntry(k, (s / 60).round()));
}

/// Sum of [records] where overlapping time is counted once: each interval
/// record contributes only the fraction of its duration not already covered
/// by an earlier-starting record. Instant records (start == end) count fully
/// unless an identical instant was already counted.
double proratedSum(Iterable<HcRecord> records) {
  final sorted = records.toList()
    ..sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.end.compareTo(b.end);
    });
  DateTime? coveredUntil;
  final instants = <int>{};
  var total = 0.0;
  for (final r in sorted) {
    final len = r.end.difference(r.start).inMilliseconds;
    if (len <= 0) {
      if (instants.add(r.start.millisecondsSinceEpoch)) total += r.value;
      continue;
    }
    final effStart = coveredUntil != null && coveredUntil.isAfter(r.start)
        ? coveredUntil
        : r.start;
    final uncovered = r.end.difference(effStart).inMilliseconds;
    if (uncovered > 0) total += r.value * uncovered / len;
    if (coveredUntil == null || r.end.isAfter(coveredUntil)) {
      coveredUntil = r.end;
    }
  }
  return total;
}

/// Per-day total for one record type after applying the single-source rule.
class DailyTotal {
  const DailyTotal({
    required this.localDate,
    required this.value,
    required this.primarySource,
    required this.otherSources,
  });

  final String localDate;
  final double value;
  final String primarySource;
  final List<String> otherSources;

  String get sourcesSummary {
    final primary = sourceAppLabel(primarySource);
    if (otherSources.isEmpty) return primary;
    return '$primary (also seen, not added: ${sourcesLabel(otherSources)})';
  }
}

/// Groups records by [dayOf] (default: local date of the record start), then
/// per day keeps only the source app with the largest pro-rated total.
Map<String, DailyTotal> dailyTotalsSingleSource(
  Iterable<HcRecord> records, {
  String Function(HcRecord r)? dayOf,
}) {
  final key = dayOf ?? (HcRecord r) => LocalDates.key(r.start);
  final byDay = <String, Map<String, List<HcRecord>>>{};
  for (final r in dedupeByUuid(records)) {
    byDay
        .putIfAbsent(key(r), () => {})
        .putIfAbsent(r.sourceApp, () => [])
        .add(r);
  }
  final out = <String, DailyTotal>{};
  byDay.forEach((day, bySource) {
    final totals = {
      for (final e in bySource.entries) e.key: proratedSum(e.value),
    };
    final ranked = totals.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final primary = ranked.first;
    out[day] = DailyTotal(
      localDate: day,
      value: primary.value,
      primarySource: primary.key,
      otherSources: [for (final e in ranked.skip(1)) e.key],
    );
  });
  return out;
}

/// The local date a sleep session belongs to: the date it ENDS on
/// ("the night of the 24th → the 25th" counts towards the 25th).
String sleepNightDate(DateTime sessionEnd) => LocalDates.key(sessionEnd);

/// Minutes slept per night using the single-source + merge rule.
Map<String, DailyTotal> sleepMinutesPerNight(Iterable<HcRecord> sessions) {
  final byNight = <String, Map<String, List<HcRecord>>>{};
  for (final s in dedupeByUuid(sessions)) {
    byNight
        .putIfAbsent(sleepNightDate(s.end), () => {})
        .putIfAbsent(s.sourceApp, () => [])
        .add(s);
  }
  final out = <String, DailyTotal>{};
  byNight.forEach((night, bySource) {
    final totals = <String, int>{};
    bySource.forEach((src, list) {
      totals[src] = mergeIntervals(
        list.map((s) => TimeInterval(s.start, s.end)),
      ).fold<int>(0, (a, i) => a + i.duration.inMinutes);
    });
    final ranked = totals.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    out[night] = DailyTotal(
      localDate: night,
      value: ranked.first.value.toDouble(),
      primarySource: ranked.first.key,
      otherSources: [for (final e in ranked.skip(1)) e.key],
    );
  });
  return out;
}

/// Active minutes per local day from exercise sessions (union of all
/// sessions so overlaps from phone + watch are not double counted).
Map<String, int> activeMinutesPerDay(Iterable<HcRecord> sessions) =>
    minutesPerLocalDay(
      dedupeByUuid(sessions).map((s) => TimeInterval(s.start, s.end)),
    );

/// A heart-rate reading kept after downsampling.
class HrBucketSample {
  const HrBucketSample({
    required this.bucketStart,
    required this.sample,
    required this.count,
    required this.min,
    required this.max,
  });

  final DateTime bucketStart;

  /// The actual (latest) reading kept for the bucket.
  final HcRecord sample;
  final int count;
  final double min;
  final double max;
}

/// Keeps at most one reading per [bucket] (default 5 min). Within a bucket
/// the source with the most readings wins; its latest reading is kept.
List<HrBucketSample> downsampleHeartRate(
  Iterable<HcRecord> samples, {
  Duration bucket = const Duration(minutes: 5),
}) {
  final ms = bucket.inMilliseconds;
  final buckets = <int, List<HcRecord>>{};
  for (final s in samples) {
    final b = (s.start.millisecondsSinceEpoch ~/ ms) * ms;
    buckets.putIfAbsent(b, () => []).add(s);
  }
  final keys = buckets.keys.toList()..sort();
  return [for (final k in keys) _pickBucket(k, buckets[k]!)];
}

HrBucketSample _pickBucket(int bucketStartMs, List<HcRecord> list) {
  final bySource = <String, List<HcRecord>>{};
  for (final s in list) {
    bySource.putIfAbsent(s.sourceApp, () => []).add(s);
  }
  final best = bySource.entries.reduce((a, b) {
    if (a.value.length != b.value.length) {
      return a.value.length > b.value.length ? a : b;
    }
    return a.key.compareTo(b.key) <= 0 ? a : b;
  }).value;
  best.sort((a, b) => a.start.compareTo(b.start));
  final values = best.map((s) => s.value);
  return HrBucketSample(
    bucketStart: DateTime.fromMillisecondsSinceEpoch(
      bucketStartMs,
      isUtc: true,
    ),
    sample: best.last,
    count: best.length,
    min: values.reduce(math.min),
    max: values.reduce(math.max),
  );
}

/// Normalises a Health Connect / plugin workout type to the cardio sport
/// types used by [CardioActivities]: run | walk | hike | ride, or null when
/// the session is not a cardio type we import.
String? normaliseCardioSport(String? workoutType) {
  final t = (workoutType ?? '').toUpperCase();
  if (t.isEmpty) return null;
  if (t.contains('RUNNING') || t == 'RUN' || t.contains('JOG')) return 'run';
  if (t.contains('HIKING') || t == 'HIKE') return 'hike';
  if (t.contains('WALKING') || t == 'WALK') return 'walk';
  if (t.contains('BIKING') ||
      t.contains('CYCLING') ||
      t == 'RIDE' ||
      t.contains('HAND_CYCLING')) {
    return 'ride';
  }
  return null;
}

/// Friendly label for a workout type name, e.g. RUNNING_TREADMILL →
/// "Running treadmill".
String workoutLabel(String? workoutType) {
  final t = (workoutType ?? 'OTHER').toLowerCase().replaceAll('_', ' ');
  if (t.isEmpty) return 'Workout';
  return t[0].toUpperCase() + t.substring(1);
}
