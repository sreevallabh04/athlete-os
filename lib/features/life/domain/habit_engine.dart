/// Deterministic habit calculations: due dates, honest streaks and
/// completion rates. Pure Dart, no I/O.
///
/// Rules (see test/features/life/habit_engine_test.dart):
/// * Daily/custom habits: the current streak counts consecutive *scheduled*
///   days that were completed. Skipped days are neutral (they neither extend
///   nor break a streak). A scheduled day with no mark breaks it, except
///   today, which is still in progress.
/// * Weekly-target habits are measured per ISO week (Mon–Sun). A week where
///   the target was met extends the streak. The current week never breaks it.
///   A finished week below target breaks it unless skips cover the shortfall
///   (skips are neutral), or it is the partial week the habit started in.
/// * Days before the habit's start date never count against the user.
/// * Completion % = done / due, with skipped days excluded from both.
library;

import '../../../core/time/clock.dart';
import 'habit_models.dart';

enum StreakUnit { days, weeks }

class StreakResult {
  const StreakResult({
    required this.current,
    required this.best,
    required this.unit,
  });
  final int current;
  final int best;
  final StreakUnit unit;

  String format(int v) => unit == StreakUnit.weeks
      ? '$v ${v == 1 ? 'week' : 'weeks'}'
      : '$v ${v == 1 ? 'day' : 'days'}';
}

class CompletionStats {
  const CompletionStats({
    required this.done,
    required this.due,
    required this.skipped,
  });
  final int done;
  final int due;
  final int skipped;

  /// 0..1, or null when nothing was due.
  double? get rate {
    if (due <= 0) return done > 0 ? 1.0 : null;
    return (done / due).clamp(0.0, 1.0);
  }

  CompletionStats operator +(CompletionStats o) => CompletionStats(
    done: done + o.done,
    due: due + o.due,
    skipped: skipped + o.skipped,
  );

  static const zero = CompletionStats(done: 0, due: 0, skipped: 0);
}

/// Combines manual completions with automatic ones. Manual marks are never
/// overridden by automatic rules.
Map<String, DayMark> mergeMarks(
  Map<String, HabitStatus> manual,
  Set<String> autoDoneDates,
) {
  final out = <String, DayMark>{
    for (final d in autoDoneDates) d: const DayMark.done(auto: true),
  };
  manual.forEach((date, status) => out[date] = DayMark(status));
  return out;
}

abstract final class HabitEngine {
  /// Number of done marks in the ISO week containing [dateKey], optionally
  /// excluding one date.
  static int doneInWeek(
    Map<String, DayMark> marks,
    String dateKey, {
    String? excluding,
  }) {
    final start = LocalDates.weekStart(dateKey);
    var n = 0;
    for (var i = 0; i < 7; i++) {
      final d = LocalDates.addDays(start, i);
      if (d == excluding) continue;
      if (marks[d]?.isDone ?? false) n++;
    }
    return n;
  }

  /// Whether the habit should appear as "due" on [dateKey].
  ///
  /// Daily/custom: scheduled days. Weekly: any day of the week until the
  /// weekly target is reached (a day that already has a mark stays visible).
  static bool isDueOn(
    HabitSchedule schedule,
    String dateKey, {
    Map<String, DayMark> marks = const {},
    String? startDate,
  }) {
    if (startDate != null && dateKey.compareTo(startDate) < 0) return false;
    if (!schedule.isWeekly) return schedule.isScheduledDay(dateKey);
    if (marks.containsKey(dateKey)) return true;
    return doneInWeek(marks, dateKey, excluding: dateKey) <
        schedule.weeklyTarget;
  }

  static StreakResult streaks({
    required HabitSchedule schedule,
    required Map<String, DayMark> marks,
    required String today,
    required String startDate,
  }) {
    final start = _effectiveStart(startDate, marks, today);
    if (schedule.isWeekly) {
      return StreakResult(
        current: _weeklyCurrent(schedule, marks, today, start),
        best: _weeklyBest(schedule, marks, today, start),
        unit: StreakUnit.weeks,
      );
    }
    return StreakResult(
      current: _dailyCurrent(schedule, marks, today, start),
      best: _dailyBest(schedule, marks, today, start),
      unit: StreakUnit.days,
    );
  }

  /// Earliest of the habit start and any recorded mark (back-filled marks
  /// count), never after today.
  static String _effectiveStart(
    String startDate,
    Map<String, DayMark> marks,
    String today,
  ) {
    var s = startDate;
    for (final d in marks.keys) {
      if (d.compareTo(s) < 0) s = d;
    }
    return s.compareTo(today) > 0 ? today : s;
  }

  static int _dailyCurrent(
    HabitSchedule schedule,
    Map<String, DayMark> marks,
    String today,
    String start,
  ) {
    var streak = 0;
    var d = today;
    while (d.compareTo(start) >= 0) {
      if (schedule.isScheduledDay(d)) {
        final m = marks[d];
        if (m == null) {
          if (d != today) break;
        } else if (m.isDone) {
          streak++;
        }
        // skipped: neutral
      }
      d = LocalDates.addDays(d, -1);
    }
    return streak;
  }

  static int _dailyBest(
    HabitSchedule schedule,
    Map<String, DayMark> marks,
    String today,
    String start,
  ) {
    var best = 0;
    var run = 0;
    for (final d in LocalDates.range(start, today)) {
      if (!schedule.isScheduledDay(d)) continue;
      final m = marks[d];
      if (m == null) {
        if (d != today) run = 0;
      } else if (m.isDone) {
        run++;
        if (run > best) best = run;
      }
    }
    return best;
  }

  /// Outcome of one ISO week for a weekly-target habit.
  static _WeekOutcome _weekOutcome(
    HabitSchedule schedule,
    Map<String, DayMark> marks,
    String weekStart,
    String today,
    String start,
  ) {
    var done = 0;
    var skipped = 0;
    for (var i = 0; i < 7; i++) {
      final d = LocalDates.addDays(weekStart, i);
      if (d.compareTo(start) < 0 || d.compareTo(today) > 0) continue;
      final m = marks[d];
      if (m == null) continue;
      if (m.isDone) {
        done++;
      } else {
        skipped++;
      }
    }
    final target = schedule.weeklyTarget;
    if (done >= target) return _WeekOutcome.met;
    final isCurrent = weekStart == LocalDates.weekStart(today);
    if (isCurrent) return _WeekOutcome.neutral;
    if (done + skipped >= target) return _WeekOutcome.neutral;
    final isStartWeek = weekStart == LocalDates.weekStart(start);
    if (isStartWeek && start != weekStart) return _WeekOutcome.neutral;
    return _WeekOutcome.missed;
  }

  static int _weeklyCurrent(
    HabitSchedule schedule,
    Map<String, DayMark> marks,
    String today,
    String start,
  ) {
    var streak = 0;
    final firstWeek = LocalDates.weekStart(start);
    var w = LocalDates.weekStart(today);
    while (w.compareTo(firstWeek) >= 0) {
      final o = _weekOutcome(schedule, marks, w, today, start);
      if (o == _WeekOutcome.met) streak++;
      if (o == _WeekOutcome.missed) break;
      w = LocalDates.addDays(w, -7);
    }
    return streak;
  }

  static int _weeklyBest(
    HabitSchedule schedule,
    Map<String, DayMark> marks,
    String today,
    String start,
  ) {
    var best = 0;
    var run = 0;
    final last = LocalDates.weekStart(today);
    var w = LocalDates.weekStart(start);
    while (w.compareTo(last) <= 0) {
      final o = _weekOutcome(schedule, marks, w, today, start);
      if (o == _WeekOutcome.met) {
        run++;
        if (run > best) best = run;
      } else if (o == _WeekOutcome.missed) {
        run = 0;
      }
      w = LocalDates.addDays(w, 7);
    }
    return best;
  }

  /// Completion between [from] and [to] (inclusive), never counting days
  /// after [today] or before the habit start. Today only counts once it has a
  /// mark, so an unfinished day never lowers the rate.
  static CompletionStats completion({
    required HabitSchedule schedule,
    required Map<String, DayMark> marks,
    required String from,
    required String to,
    required String today,
    required String startDate,
  }) {
    final start = _effectiveStart(startDate, marks, today);
    final lo = from.compareTo(start) < 0 ? start : from;
    final hi = to.compareTo(today) > 0 ? today : to;
    if (lo.compareTo(hi) > 0) return CompletionStats.zero;

    if (!schedule.isWeekly) {
      var done = 0, due = 0, skipped = 0;
      for (final d in LocalDates.range(lo, hi)) {
        if (!schedule.isScheduledDay(d)) continue;
        final m = marks[d];
        if (m == null) {
          if (d != today) due++;
        } else if (m.isDone) {
          done++;
          due++;
        } else {
          skipped++;
        }
      }
      return CompletionStats(done: done, due: due, skipped: skipped);
    }

    // Weekly: per ISO week, due = target minus skips (never below 0). The
    // current week only counts what has been done so far.
    var total = CompletionStats.zero;
    var w = LocalDates.weekStart(lo);
    while (w.compareTo(hi) <= 0) {
      var done = 0, skipped = 0;
      for (var i = 0; i < 7; i++) {
        final d = LocalDates.addDays(w, i);
        if (d.compareTo(lo) < 0 || d.compareTo(hi) > 0) continue;
        final m = marks[d];
        if (m == null) continue;
        if (m.isDone) {
          done++;
        } else {
          skipped++;
        }
      }
      final isCurrent = w == LocalDates.weekStart(today);
      final due = (schedule.weeklyTarget - skipped).clamp(0, 7);
      final counted = done > due ? due : done;
      if (isCurrent && counted < due) {
        // The week is still in progress and the target isn't met yet: it
        // can't be judged, so it doesn't count either way.
        w = LocalDates.addDays(w, 7);
        continue;
      }
      total += CompletionStats(done: counted, due: due, skipped: skipped);
      w = LocalDates.addDays(w, 7);
    }
    return total;
  }

  /// ISO-week progress for the week containing [today].
  ///
  /// Daily/custom: done / elapsed scheduled days (skips excluded, today only
  /// once marked). Weekly target: progress toward the target, where skips
  /// lower the target (done is capped at the target).
  static CompletionStats weekProgress({
    required HabitSchedule schedule,
    required Map<String, DayMark> marks,
    required String today,
    required String startDate,
  }) {
    final from = LocalDates.weekStart(today);
    if (!schedule.isWeekly) {
      return completion(
        schedule: schedule,
        marks: marks,
        from: from,
        to: today,
        today: today,
        startDate: startDate,
      );
    }
    final start = _effectiveStart(startDate, marks, today);
    var done = 0, skipped = 0;
    for (final d in LocalDates.range(from, today)) {
      if (d.compareTo(start) < 0) continue;
      final m = marks[d];
      if (m == null) continue;
      if (m.isDone) {
        done++;
      } else {
        skipped++;
      }
    }
    final due = (schedule.weeklyTarget - skipped).clamp(0, 7);
    return CompletionStats(
      done: done > due ? due : done,
      due: due,
      skipped: skipped,
    );
  }

  /// Habits whose prerequisite (dependsOnHabitId) is done today while they
  /// themselves are due and not yet marked. Shown as "Up next".
  static Set<String> suggestedNext(Iterable<HabitDependencyView> habits) {
    final byId = {for (final h in habits) h.id: h};
    final out = <String>{};
    for (final h in habits) {
      final dep = h.dependsOnId;
      if (dep == null) continue;
      final parent = byId[dep];
      if (parent == null) continue;
      if ((parent.todayMark?.isDone ?? false) &&
          h.dueToday &&
          h.todayMark == null) {
        out.add(h.id);
      }
    }
    return out;
  }
}

enum _WeekOutcome { met, neutral, missed }

/// Minimal view used by [HabitEngine.suggestedNext].
class HabitDependencyView {
  const HabitDependencyView({
    required this.id,
    required this.dependsOnId,
    required this.dueToday,
    required this.todayMark,
  });
  final String id;
  final String? dependsOnId;
  final bool dueToday;
  final DayMark? todayMark;
}
