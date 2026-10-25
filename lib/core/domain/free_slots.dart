/// A half-open time interval [start, end).
class TimeInterval {
  const TimeInterval(this.start, this.end);
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
  bool overlaps(TimeInterval o) =>
      start.isBefore(o.end) && o.start.isBefore(end);

  @override
  String toString() => 'TimeInterval($start – $end)';

  @override
  bool operator ==(Object other) =>
      other is TimeInterval && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Merges overlapping/adjacent intervals. Input order does not matter.
List<TimeInterval> mergeIntervals(Iterable<TimeInterval> input) {
  final sorted = input.where((i) => i.end.isAfter(i.start)).toList()
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

/// Deterministically finds free slots of at least [minDuration] inside
/// [window], avoiding [busy] intervals padded by [buffer] on each side.
/// Used by the planner and the AI `suggest_schedule` tool so suggestions never
/// conflict with existing events.
List<TimeInterval> findFreeSlots({
  required TimeInterval window,
  required Iterable<TimeInterval> busy,
  required Duration minDuration,
  Duration buffer = Duration.zero,
}) {
  final padded = busy.map(
    (b) => TimeInterval(b.start.subtract(buffer), b.end.add(buffer)),
  );
  final merged = mergeIntervals(padded.where((b) => b.overlaps(window)));
  final out = <TimeInterval>[];
  var cursor = window.start;
  for (final b in merged) {
    if (b.start.isAfter(cursor)) {
      final gap = TimeInterval(
        cursor,
        b.start.isBefore(window.end) ? b.start : window.end,
      );
      if (gap.duration >= minDuration) out.add(gap);
    }
    if (b.end.isAfter(cursor)) cursor = b.end;
    if (!cursor.isBefore(window.end)) break;
  }
  if (cursor.isBefore(window.end)) {
    final gap = TimeInterval(cursor, window.end);
    if (gap.duration >= minDuration) out.add(gap);
  }
  return out;
}
