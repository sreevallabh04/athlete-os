/// Pure, deterministic reminder time planner.
///
/// Given a pattern (interval within the wake window, fixed daily times, or
/// specific dates), the user's wake/sleep window, global quiet hours and busy
/// calendar intervals, it produces concrete zoned instants for the next N
/// days. All wall-clock maths happens in the target [tz.Location] so results
/// are correct across DST transitions (a 09:00 reminder stays at 09:00 local
/// time on the day the clocks change).
library;

import 'package:timezone/timezone.dart' as tz;

import '../../../core/domain/free_slots.dart';
import 'habit_models.dart';

/// Quiet hours in minutes after local midnight. Supports overnight ranges
/// such as 22:00–07:00 (start > end). start == end means "off".
class QuietHours {
  const QuietHours(this.start, this.end);
  final int start;
  final int end;

  bool get isEmpty => start == end;
  bool get isOvernight => start > end;

  bool contains(int minuteOfDay) {
    if (isEmpty) return false;
    final m = minuteOfDay % 1440;
    if (start < end) return m >= start && m < end;
    return m >= start || m < end;
  }

  Map<String, int> toJson() => {'start': start, 'end': end};

  static QuietHours? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['start'];
    final e = json['end'];
    if (s is! num || e is! num) return null;
    final qh = QuietHours(s.toInt() % 1440, e.toInt() % 1440);
    return qh.isEmpty ? null : qh;
  }

  @override
  String toString() =>
      'QuietHours(${formatMinutes(start)}–${formatMinutes(end)})';
}

sealed class ReminderPattern {
  const ReminderPattern();
}

/// Every [intervalMinutes] inside the wake window, starting one interval
/// after waking (e.g. water reminders).
class IntervalPattern extends ReminderPattern {
  const IntervalPattern(this.intervalMinutes);
  final int intervalMinutes;
}

/// Fixed local times on the weekdays in [daysMask] (bit0 = Mon).
class FixedTimesPattern extends ReminderPattern {
  const FixedTimesPattern(this.times, {this.daysMask = allDaysMask});
  final List<int> times;
  final int daysMask;
}

/// One time on each of the given local dates (YYYY-MM-DD).
class DatesPattern extends ReminderPattern {
  const DatesPattern(this.dates, this.time);
  final Set<String> dates;
  final int time;
}

/// Longest delay applied when moving a fixed reminder out of a busy block.
const maxBusyShift = Duration(hours: 3);

/// Plans reminder instants for [days] calendar days starting with the day of
/// [now] (only instants strictly after [now] are returned).
///
/// * Interval reminders stay inside the wake window (wake → sleep; a sleep
///   time earlier than the wake time means after midnight) and are dropped
///   if they fall in a busy block, since another one follows soon.
/// * Fixed/date reminders ignore the wake window (the user picked the time)
///   but are moved to the end of a busy block when that keeps them on the
///   same day, outside quiet hours and within [maxBusyShift]; otherwise they
///   keep their original time.
/// * Nothing is ever scheduled inside quiet hours.
/// * Results are sorted, de-duplicated to the minute and capped at
///   [maxPerDay] per local day (earliest kept).
List<tz.TZDateTime> planReminderTimes({
  required ReminderPattern pattern,
  required tz.TZDateTime now,
  required int days,
  int wakeMinutes = 390,
  int sleepMinutes = 1350,
  QuietHours? quietHours,
  List<TimeInterval> busy = const [],
  int? maxPerDay,
}) {
  final loc = now.location;
  final mergedBusy = mergeIntervals(busy);
  final candidates = <tz.TZDateTime>[];

  for (var i = 0; i < days; i++) {
    final y = now.year, mo = now.month, d = now.day + i;
    // Normalised calendar date for this offset (UTC used purely as a
    // calendar so the device timezone can't interfere).
    final day = DateTime.utc(y, mo, d);
    final dateKey = _ymd(day.year, day.month, day.day);

    switch (pattern) {
      case IntervalPattern(:final intervalMinutes):
        if (intervalMinutes < 15) break;
        final start = wakeMinutes % 1440;
        var end = sleepMinutes % 1440;
        if (end <= start) end += 1440;
        for (var m = start + intervalMinutes; m < end; m += intervalMinutes) {
          final t = _at(loc, day, m);
          if (_inQuiet(t, quietHours)) continue;
          if (_busyAt(t, mergedBusy) != null) continue;
          candidates.add(t);
        }
      case FixedTimesPattern(:final times, :final daysMask):
        if (!maskHasWeekday(daysMask, day.weekday)) break;
        for (final m in times) {
          final t = _shiftForBusy(_at(loc, day, m), mergedBusy, quietHours);
          if (t != null) candidates.add(t);
        }
      case DatesPattern(:final dates, :final time):
        if (!dates.contains(dateKey)) break;
        final t = _shiftForBusy(_at(loc, day, time), mergedBusy, quietHours);
        if (t != null) candidates.add(t);
    }
  }

  candidates.sort();
  final seen = <int>{};
  final perDay = <String, int>{};
  final out = <tz.TZDateTime>[];
  for (final t in candidates) {
    if (!t.isAfter(now)) continue;
    final minuteKey = t.millisecondsSinceEpoch ~/ 60000;
    if (!seen.add(minuteKey)) continue;
    final key = _dateKey(t);
    final count = perDay[key] ?? 0;
    if (maxPerDay != null && count >= maxPerDay) continue;
    perDay[key] = count + 1;
    out.add(t);
  }
  return out;
}

tz.TZDateTime _at(tz.Location loc, DateTime day, int minutes) =>
    tz.TZDateTime(loc, day.year, day.month, day.day, 0, minutes);

String _dateKey(tz.TZDateTime t) => _ymd(t.year, t.month, t.day);

String _ymd(int y, int m, int d) =>
    '${y.toString().padLeft(4, '0')}-'
    '${m.toString().padLeft(2, '0')}-'
    '${d.toString().padLeft(2, '0')}';

bool _inQuiet(tz.TZDateTime t, QuietHours? q) =>
    q != null && q.contains(t.hour * 60 + t.minute);

TimeInterval? _busyAt(DateTime t, List<TimeInterval> merged) {
  for (final b in merged) {
    if (!t.isBefore(b.start) && t.isBefore(b.end)) return b;
  }
  return null;
}

/// Returns the reminder time adjusted for busy blocks, or null when it falls
/// in quiet hours.
tz.TZDateTime? _shiftForBusy(
  tz.TZDateTime t,
  List<TimeInterval> merged,
  QuietHours? quiet,
) {
  if (_inQuiet(t, quiet)) return null;
  final b = _busyAt(t, merged);
  if (b == null) return t;
  final shifted = tz.TZDateTime.from(b.end, t.location);
  final sameDay = _dateKey(shifted) == _dateKey(t);
  if (sameDay &&
      shifted.difference(t) <= maxBusyShift &&
      !_inQuiet(shifted, quiet)) {
    return shifted;
  }
  return t;
}
