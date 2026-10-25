// Deterministic time-slot suggestions for creating calendar blocks.
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/domain/free_slots.dart';
import '../../../core/time/clock.dart';

/// Kinds of blocks the user can add to their calendar from the app.
enum PlanKind {
  workout('workout', 'Workout', Duration(minutes: 60)),
  mealPrep('meal_prep', 'Meal prep', Duration(minutes: 90)),
  focus('focus', 'Focus block', Duration(minutes: 90)),
  habit('habit', 'Habit', Duration(minutes: 30));

  const PlanKind(this.key, this.label, this.defaultDuration);
  final String key;
  final String label;
  final Duration defaultDuration;
}

DateTime _ceilTo(DateTime t, Duration step) {
  final ms = step.inMilliseconds;
  final epoch = t.millisecondsSinceEpoch;
  final rem = epoch % ms;
  if (rem == 0) return t;
  return DateTime.fromMillisecondsSinceEpoch(epoch + ms - rem, isUtc: t.isUtc);
}

/// Waking-hours window for [dayKey] in device local time.
TimeInterval wakingWindow(String dayKey, int wakeMinutes, int sleepMinutes) {
  final d = LocalDates.parse(dayKey);
  final start = DateTime(d.year, d.month, d.day, 0, wakeMinutes);
  var endMin = sleepMinutes;
  if (endMin <= wakeMinutes) endMin += 24 * 60;
  final end = DateTime(d.year, d.month, d.day, 0, endMin);
  return TimeInterval(start, end);
}

List<TimeInterval> busyIntervals(Iterable<CalendarEventView> events) => [
  for (final e in events)
    if (e.isBusy) TimeInterval(e.start, e.end),
];

/// Suggests up to [max] start slots of [duration] on [dayKey] between wake
/// and sleep time that don't overlap busy events (± [buffer]) and are not in
/// the past. At most two suggestions per free gap on the first pass so the
/// options are spread across the day.
List<TimeInterval> suggestSlots({
  required String dayKey,
  required Iterable<CalendarEventView> events,
  required Duration duration,
  required int wakeMinutes,
  required int sleepMinutes,
  required DateTime now,
  Duration buffer = const Duration(minutes: 10),
  Duration step = const Duration(minutes: 30),
  int max = 6,
}) {
  final day = wakingWindow(dayKey, wakeMinutes, sleepMinutes);
  final earliest = _ceilTo(now, const Duration(minutes: 15));
  final start = earliest.isAfter(day.start) ? earliest : day.start;
  if (!start.isBefore(day.end)) return const [];
  final free = findFreeSlots(
    window: TimeInterval(start, day.end),
    busy: busyIntervals(events),
    minDuration: duration,
    buffer: buffer,
  );
  final perGap = <List<TimeInterval>>[];
  for (final gap in free) {
    final list = <TimeInterval>[];
    var s = _ceilTo(gap.start, const Duration(minutes: 15));
    while (!s.add(duration).isAfter(gap.end)) {
      list.add(TimeInterval(s, s.add(duration)));
      s = s.add(step);
    }
    perGap.add(list);
  }
  final out = <TimeInterval>[];
  for (final pass in [2, 1 << 30]) {
    for (final g in perGap) {
      for (final c in g.take(pass)) {
        if (out.length >= max) break;
        if (!out.contains(c)) out.add(c);
      }
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Busy events overlapping [candidate] — checked again right before insert.
List<CalendarEventView> conflictsFor(
  TimeInterval candidate,
  Iterable<CalendarEventView> events,
) => [
  for (final e in events)
    if (e.isBusy && TimeInterval(e.start, e.end).overlaps(candidate)) e,
];
