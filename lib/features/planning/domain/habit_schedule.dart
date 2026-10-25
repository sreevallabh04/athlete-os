/// Pure habit scheduling rules shared by Today, Planner and Reports.
library;

/// Minimal, storage-independent view of a habit.
class HabitSpec {
  const HabitSpec({
    required this.id,
    required this.name,
    this.scheduleType = 'daily',
    this.daysMask = 127,
    this.targetPerWeek,
    this.archived = false,
  });

  final String id;
  final String name;

  /// daily | weekly | custom
  final String scheduleType;

  /// Bitmask Mon=1<<0 ... Sun=1<<6 (used for `custom`).
  final int daysMask;
  final int? targetPerWeek;
  final bool archived;
}

/// A completion record (status `done` or `skipped`).
class HabitMark {
  const HabitMark(this.habitId, this.localDate, this.status);
  final String habitId;
  final String localDate;
  final String status;
  bool get isDone => status == 'done';
}

enum HabitDayState {
  /// Not scheduled for this day (custom days) or archived.
  notScheduled,

  /// Scheduled and not yet completed.
  due,
  done,
  skipped,

  /// Weekly habit whose weekly target is already met on earlier days.
  weeklyTargetMet,
}

DateTime _parse(String key) {
  final p = key.split('-');
  return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

String _key(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Monday (ISO) of the week containing [dateKey].
String mondayOf(String dateKey) {
  final d = _parse(dateKey);
  return _key(d.subtract(Duration(days: d.weekday - DateTime.monday)));
}

/// Whether a daily/custom habit is scheduled on [dateKey]. Weekly habits are
/// "available" every day; whether they are due depends on weekly progress.
bool isScheduledOn(HabitSpec h, String dateKey) {
  if (h.archived) return false;
  switch (h.scheduleType) {
    case 'custom':
      final weekday = _parse(dateKey).weekday; // 1 = Monday
      return (h.daysMask & (1 << (weekday - 1))) != 0;
    case 'weekly':
    case 'daily':
    default:
      return true;
  }
}

/// State of [h] on [dateKey] given all of its [marks] (any dates).
HabitDayState habitStateOn(
  HabitSpec h,
  String dateKey,
  Iterable<HabitMark> marks,
) {
  if (!isScheduledOn(h, dateKey)) return HabitDayState.notScheduled;
  final mine = marks.where((m) => m.habitId == h.id);
  for (final m in mine) {
    if (m.localDate == dateKey) {
      return m.isDone ? HabitDayState.done : HabitDayState.skipped;
    }
  }
  if (h.scheduleType == 'weekly') {
    final monday = mondayOf(dateKey);
    final doneEarlier = mine
        .where(
          (m) =>
              m.isDone &&
              m.localDate.compareTo(monday) >= 0 &&
              m.localDate.compareTo(dateKey) < 0,
        )
        .length;
    if (doneEarlier >= (h.targetPerWeek ?? 1)) {
      return HabitDayState.weeklyTargetMet;
    }
  }
  return HabitDayState.due;
}

/// Today's habit tally: how many habits were due today and how many are done.
class HabitTally {
  const HabitTally({required this.done, required this.remaining});
  final int done;
  final int remaining;
  int get total => done + remaining;
}

HabitTally tallyHabits(
  Iterable<HabitSpec> habits,
  String dateKey,
  Iterable<HabitMark> marks,
) {
  var done = 0;
  var remaining = 0;
  for (final h in habits) {
    switch (habitStateOn(h, dateKey, marks)) {
      case HabitDayState.done:
        done++;
      case HabitDayState.due:
        remaining++;
      case HabitDayState.skipped:
      case HabitDayState.notScheduled:
      case HabitDayState.weeklyTargetMet:
        break;
    }
  }
  return HabitTally(done: done, remaining: remaining);
}

/// Completion rate over an inclusive date range: completed / expected.
/// Daily/custom habits expect one completion per scheduled day; weekly habits
/// expect `targetPerWeek` per Monday-start week touched by the range
/// (pro-rated by the fraction of that week inside the range).
({int expected, int completed}) habitCompletion(
  Iterable<HabitSpec> habits,
  List<String> dates,
  Iterable<HabitMark> marks,
) {
  if (dates.isEmpty) return (expected: 0, completed: 0);
  final dateSet = dates.toSet();
  var expected = 0;
  var completed = 0;
  for (final h in habits.where((h) => !h.archived)) {
    final mine = marks.where(
      (m) => m.habitId == h.id && m.isDone && dateSet.contains(m.localDate),
    );
    if (h.scheduleType == 'weekly') {
      final byWeek = <String, int>{};
      final daysInWeek = <String, int>{};
      for (final d in dates) {
        daysInWeek.update(mondayOf(d), (v) => v + 1, ifAbsent: () => 1);
      }
      for (final m in mine) {
        byWeek.update(mondayOf(m.localDate), (v) => v + 1, ifAbsent: () => 1);
      }
      final target = h.targetPerWeek ?? 1;
      for (final entry in daysInWeek.entries) {
        final exp = (target * entry.value / 7).ceil();
        expected += exp;
        completed += (byWeek[entry.key] ?? 0).clamp(0, exp);
      }
    } else {
      final scheduled = dates.where((d) => isScheduledOn(h, d)).toSet();
      expected += scheduled.length;
      completed += mine.where((m) => scheduled.contains(m.localDate)).length;
    }
  }
  return (expected: expected, completed: completed);
}
