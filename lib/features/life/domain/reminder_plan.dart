/// Turns reminder preferences + app data into a concrete, deterministic list
/// of notifications with stable ids. Pure Dart (timezone maths only).
library;

import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import '../../../core/domain/free_slots.dart';
import 'habit_engine.dart';
import 'habit_models.dart';
import 'reminder_kinds.dart';
import 'reminder_scheduler.dart';

class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.kind,
    required this.when,
    required this.title,
    required this.body,
    required this.payload,
  });

  final int id;
  final ReminderKind kind;
  final tz.TZDateTime when;
  final String title;
  final String body;

  /// JSON payload: {"k": kind key, "h"?: habit id, "at": ISO instant}.
  final String payload;

  @override
  String toString() => 'Planned($id ${kind.key} $when "$title")';
}

class HabitReminderSource {
  const HabitReminderSource({
    required this.id,
    required this.name,
    required this.reminderTimes,
    required this.schedule,
    required this.startDate,
    this.marks = const {},
  });
  final String id;
  final String name;
  final List<int> reminderTimes;
  final HabitSchedule schedule;
  final String startDate;

  /// Marks for at least the current ISO week.
  final Map<String, DayMark> marks;
}

class MilestoneReminderSource {
  const MilestoneReminderSource({
    required this.id,
    required this.title,
    required this.dueDate,
    this.competitionName,
  });
  final String id;
  final String title;
  final String dueDate;
  final String? competitionName;
}

class ReminderPlanInput {
  const ReminderPlanInput({
    required this.prefs,
    required this.now,
    this.days = 7,
    this.wakeMinutes = 390,
    this.sleepMinutes = 1350,
    this.quietHours,
    this.busy = const [],
    this.habits = const [],
    this.milestones = const [],
    this.competitionHorizonDays = 60,
  });

  final Map<ReminderKind, ReminderPref> prefs;
  final tz.TZDateTime now;
  final int days;
  final int wakeMinutes;
  final int sleepMinutes;
  final QuietHours? quietHours;
  final List<TimeInterval> busy;
  final List<HabitReminderSource> habits;
  final List<MilestoneReminderSource> milestones;
  final int competitionHorizonDays;
}

String _ymd(tz.TZDateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// Builds the full plan for every enabled kind.
List<PlannedNotification> buildReminderPlan(ReminderPlanInput input) {
  final out = <PlannedNotification>[];
  for (final kind in ReminderKind.values) {
    final pref = input.prefs[kind];
    if (pref == null || !pref.enabled) continue;
    out.addAll(planKind(kind, pref.config, input));
  }
  return out;
}

/// Plans one kind. Ids are idBase + index in chronological order, so
/// re-planning replaces exactly the same id range.
List<PlannedNotification> planKind(
  ReminderKind kind,
  ReminderConfig config,
  ReminderPlanInput input,
) {
  final items = <(tz.TZDateTime, String, String, Map<String, Object?>)>[];

  List<tz.TZDateTime> plan(ReminderPattern p, {int? maxPerDay, int? days}) =>
      planReminderTimes(
        pattern: p,
        now: input.now,
        days: days ?? input.days,
        wakeMinutes: input.wakeMinutes,
        sleepMinutes: input.sleepMinutes,
        quietHours: input.quietHours,
        busy: input.busy,
        maxPerDay: maxPerDay,
      );

  switch (kind.shape) {
    case ConfigShape.interval:
      for (final t in plan(
        IntervalPattern(config.intervalMinutes),
        maxPerDay: config.maxPerDay,
      )) {
        items.add((t, kind.title, kind.body, {}));
      }
    case ConfigShape.timeAndDays ||
        ConfigShape.timesAndDays ||
        ConfigShape.weekly:
      final times = kind.shape == ConfigShape.timesAndDays
          ? config.times
          : config.times.take(1).toList();
      for (final t in plan(
        FixedTimesPattern(times, daysMask: config.daysMask),
      )) {
        items.add((t, kind.title, kind.body, {}));
      }
    case ConfigShape.timeOnly:
      final time = config.times.isEmpty ? 480 : config.times.first;
      final today = _ymd(input.now);
      for (final m in input.milestones) {
        if (m.dueDate.compareTo(today) < 0) continue;
        final ts = plan(
          DatesPattern({m.dueDate}, time),
          days: input.competitionHorizonDays,
        );
        final body = m.competitionName == null || m.competitionName!.isEmpty
            ? m.title
            : '${m.title} · ${m.competitionName}';
        for (final t in ts) {
          items.add((t, kind.title, body, {'m': m.id}));
        }
      }
    case ConfigShape.perItem:
      final today = _ymd(input.now);
      for (final h in input.habits) {
        if (h.reminderTimes.isEmpty) continue;
        final mask = h.schedule.type == HabitScheduleType.custom
            ? h.schedule.daysMask
            : allDaysMask;
        final weekTargetMet =
            h.schedule.isWeekly &&
            HabitEngine.doneInWeek(h.marks, today) >= h.schedule.weeklyTarget;
        final thisWeekEnd = _weekEnd(today);
        for (final t in plan(
          FixedTimesPattern(h.reminderTimes, daysMask: mask),
        )) {
          final d = _ymd(t);
          if (d.compareTo(h.startDate) < 0) continue;
          // Already marked today (done or skipped): no reminder needed.
          if (d == today && h.marks.containsKey(today)) continue;
          if (weekTargetMet && d.compareTo(thisWeekEnd) <= 0) continue;
          items.add((t, h.name, kind.body, {'h': h.id}));
        }
      }
  }

  items.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final capped = items.take(ReminderKind.maxPerKind).toList();
  return [
    for (var i = 0; i < capped.length; i++)
      PlannedNotification(
        id: kind.idBase + i,
        kind: kind,
        when: capped[i].$1,
        title: capped[i].$2,
        body: capped[i].$3,
        payload: jsonEncode({
          'k': kind.key,
          ...capped[i].$4,
          'at': capped[i].$1.toUtc().toIso8601String(),
        }),
      ),
  ];
}

String _weekEnd(String dateKey) {
  final p = dateKey.split('-').map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2]);
  final end = d.add(Duration(days: 7 - d.weekday));
  return '${end.year.toString().padLeft(4, '0')}-'
      '${end.month.toString().padLeft(2, '0')}-'
      '${end.day.toString().padLeft(2, '0')}';
}
