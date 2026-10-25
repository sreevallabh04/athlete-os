/// Deterministic "smart daily summary". Each sentence is produced only when
/// its underlying data exists; missing sources are listed as unavailable so
/// the UI never shows invented numbers.
library;

import '../../../core/util/format.dart';
import '../../planning/domain/metrics.dart' show sourceLabel;

class StepsFact {
  const StepsFact({
    required this.steps,
    required this.goal,
    required this.origin,
    this.asOf,
  });
  final int steps;
  final int goal;
  final String origin;
  final DateTime? asOf;
}

class NutritionFact {
  const NutritionFact({
    required this.entries,
    required this.kcal,
    required this.proteinG,
    required this.kcalTarget,
    required this.proteinTargetG,
  });
  final int entries;
  final double kcal;
  final double proteinG;
  final int kcalTarget;
  final double proteinTargetG;
}

class EventFact {
  const EventFact({
    required this.title,
    required this.start,
    this.allDay = false,
  });
  final String title;
  final DateTime start;
  final bool allDay;
}

/// connected=false → not connected; error != null → failed to load.
class CalendarFact {
  const CalendarFact({
    required this.connected,
    this.error,
    this.events = const [],
  });
  final bool connected;
  final String? error;
  final List<EventFact> events;
}

class SleepFact {
  const SleepFact({required this.minutes, required this.origin, this.asOf});
  final int minutes;
  final String origin;
  final DateTime? asOf;
}

class WaterFact {
  const WaterFact({required this.ml, required this.goalMl});
  final int ml;
  final int goalMl;
}

class SummaryInput {
  const SummaryInput({
    required this.now,
    this.competitionHeadline,
    this.steps,
    this.nutrition,
    this.water,
    this.calendar,
    this.calendarPending = false,
    this.plannedWorkout,
    this.completedWorkout,
    this.sleep,
  });

  final DateTime now;
  final String? competitionHeadline;
  final StepsFact? steps;
  final NutritionFact? nutrition;
  final WaterFact? water;
  final CalendarFact? calendar;

  /// True while calendar events are still loading: no calendar clause and no
  /// "unavailable" chip yet.
  final bool calendarPending;

  /// Title of a planned (not yet done) workout today, if any.
  final String? plannedWorkout;

  /// (title, source) of a workout already recorded today, if any.
  final (String, String)? completedWorkout;
  final SleepFact? sleep;
}

enum SummaryTopic {
  competition,
  steps,
  protein,
  calories,
  water,
  calendar,
  workout,
  sleep,
}

class SummaryLine {
  const SummaryLine(this.topic, this.text);
  final SummaryTopic topic;
  final String text;
  @override
  String toString() => text;
}

class DailySummary {
  const DailySummary(this.lines, this.unavailable);
  final List<SummaryLine> lines;

  /// Human labels of data that could not be summarised (e.g. "Steps").
  final List<String> unavailable;
}

String _provenance(String origin, DateTime? asOf, DateTime now) {
  final label = sourceLabel(origin);
  return asOf == null ? label : '$label, ${Fmt.ago(asOf, now)}';
}

DailySummary buildDailySummary(SummaryInput i) {
  final lines = <SummaryLine>[];
  final missing = <String>[];

  if (i.competitionHeadline != null) {
    lines.add(
      SummaryLine(SummaryTopic.competition, '${i.competitionHeadline}.'),
    );
  }

  final s = i.steps;
  if (s != null) {
    final p = _provenance(s.origin, s.asOf, i.now);
    final remaining = s.goal - s.steps;
    lines.add(
      SummaryLine(
        SummaryTopic.steps,
        remaining > 0
            ? "You're ${Fmt.integer(remaining)} steps away from your "
                  '${Fmt.integer(s.goal)} goal ($p).'
            : "You've hit your ${Fmt.integer(s.goal)}-step goal with "
                  '${Fmt.integer(s.steps)} steps ($p).',
      ),
    );
  } else {
    missing.add('Steps');
  }

  final n = i.nutrition;
  if (n != null && n.entries > 0) {
    final protein = n.proteinG.round();
    final toGo = (n.proteinTargetG - n.proteinG).round();
    lines.add(
      SummaryLine(
        SummaryTopic.protein,
        toGo > 0
            ? "You've logged $protein g protein — $toGo g to go."
            : "You've reached your protein target ($protein g of "
                  '${n.proteinTargetG.round()} g).',
      ),
    );
    final kcalLeft = (n.kcalTarget - n.kcal).round();
    lines.add(
      SummaryLine(
        SummaryTopic.calories,
        kcalLeft >= 0
            ? '${Fmt.integer(kcalLeft)} kcal left of your '
                  '${Fmt.integer(n.kcalTarget)} kcal target.'
            : "You're ${Fmt.integer(-kcalLeft)} kcal over your "
                  '${Fmt.integer(n.kcalTarget)} kcal target.',
      ),
    );
  } else {
    missing.add('Food log');
  }

  final w = i.water;
  if (w != null && w.ml > 0) {
    final left = w.goalMl - w.ml;
    lines.add(
      SummaryLine(
        SummaryTopic.water,
        left > 0
            ? 'Water: ${Fmt.ml(w.ml)} of ${Fmt.ml(w.goalMl)} — '
                  '${Fmt.ml(left)} to go.'
            : 'Water goal reached (${Fmt.ml(w.ml)}).',
      ),
    );
  } else {
    missing.add('Water');
  }

  final c = i.calendar;
  if (i.calendarPending) {
    // Wait for the calendar before saying anything about it.
  } else if (c == null || !c.connected) {
    missing.add('Calendar (not connected)');
  } else if (c.error != null) {
    missing.add('Calendar (could not load)');
  } else {
    final upcoming =
        c.events.where((e) => !e.allDay && e.start.isAfter(i.now)).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    lines.add(
      SummaryLine(
        SummaryTopic.calendar,
        upcoming.isEmpty
            ? 'No more timed calendar events today.'
            : 'Next event: ${upcoming.first.title} at '
                  '${Fmt.time(upcoming.first.start)}.',
      ),
    );
  }

  if (i.completedWorkout != null) {
    final (title, source) = i.completedWorkout!;
    lines.add(
      SummaryLine(
        SummaryTopic.workout,
        'Workout logged: $title (${sourceLabel(source)}).',
      ),
    );
  } else if (i.plannedWorkout != null) {
    lines.add(
      SummaryLine(
        SummaryTopic.workout,
        'Planned workout: ${i.plannedWorkout}.',
      ),
    );
  }

  final sl = i.sleep;
  if (sl != null && sl.minutes > 0) {
    lines.add(
      SummaryLine(
        SummaryTopic.sleep,
        'You slept ${sl.minutes ~/ 60} h ${sl.minutes % 60} m last night '
        '(${sourceLabel(sl.origin)}).',
      ),
    );
  } else {
    missing.add('Sleep');
  }

  return DailySummary(lines, missing);
}
