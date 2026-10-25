import 'package:athlete_os/core/util/format.dart';
import 'package:athlete_os/features/today/domain/daily_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 25, 14, 0);

  test(
    'only clauses with data are produced; everything else is unavailable',
    () {
      final s = buildDailySummary(SummaryInput(now: now));
      expect(s.lines, isEmpty);
      expect(s.unavailable, [
        'Steps',
        'Food log',
        'Water',
        'Calendar (not connected)',
        'Sleep',
      ]);
    },
  );

  test(
    'zero food entries and zero water are unavailable, not "0 g logged"',
    () {
      final s = buildDailySummary(
        SummaryInput(
          now: now,
          nutrition: const NutritionFact(
            entries: 0,
            kcal: 0,
            proteinG: 0,
            kcalTarget: 2000,
            proteinTargetG: 150,
          ),
          water: const WaterFact(ml: 0, goalMl: 3000),
        ),
      );
      expect(s.lines, isEmpty);
      expect(s.unavailable, containsAll(['Food log', 'Water']));
    },
  );

  test('full day produces deterministic sentences with provenance', () {
    final s = buildDailySummary(
      SummaryInput(
        now: now,
        competitionHeadline: '42 days to State Classic',
        steps: StepsFact(
          steps: 8150,
          goal: 10000,
          origin: 'health_connect',
          asOf: now.subtract(const Duration(minutes: 12)),
        ),
        nutrition: const NutritionFact(
          entries: 4,
          kcal: 1250,
          proteinG: 92,
          kcalTarget: 2000,
          proteinTargetG: 150,
        ),
        water: const WaterFact(ml: 1200, goalMl: 3000),
        calendar: CalendarFact(
          connected: true,
          events: [
            EventFact(title: 'Standup', start: DateTime(2026, 10, 25, 9)),
            EventFact(title: 'Team sync', start: DateTime(2026, 10, 25, 15)),
            EventFact(
              title: 'Holiday',
              start: DateTime(2026, 10, 25),
              allDay: true,
            ),
          ],
        ),
        plannedWorkout: 'Push day',
        sleep: const SleepFact(minutes: 432, origin: 'health_connect'),
      ),
    );
    expect(s.unavailable, isEmpty);
    expect(s.lines.map((l) => l.text).toList(), [
      '42 days to State Classic.',
      "You're 1,850 steps away from your 10,000 goal (Health Connect, 12 min ago).",
      "You've logged 92 g protein — 58 g to go.",
      '750 kcal left of your 2,000 kcal target.',
      'Water: 1.2 L of 3 L — 1.8 L to go.',
      'Next event: Team sync at ${Fmt.time(DateTime(2026, 10, 25, 15))}.',
      'Planned workout: Push day.',
      'You slept 7 h 12 m last night (Health Connect).',
    ]);
  });

  test('goals reached and over-target phrasing', () {
    final s = buildDailySummary(
      SummaryInput(
        now: now,
        steps: const StepsFact(steps: 11240, goal: 10000, origin: 'manual'),
        nutrition: const NutritionFact(
          entries: 5,
          kcal: 2150,
          proteinG: 155,
          kcalTarget: 2000,
          proteinTargetG: 150,
        ),
        water: const WaterFact(ml: 3100, goalMl: 3000),
        completedWorkout: ('Upper A', 'hevy'),
        plannedWorkout: 'ignored when a workout is logged',
      ),
    );
    final texts = s.lines.map((l) => l.text).toList();
    expect(
      texts,
      contains("You've hit your 10,000-step goal with 11,240 steps (Manual)."),
    );
    expect(
      texts,
      contains("You've reached your protein target (155 g of 150 g)."),
    );
    expect(texts, contains("You're 150 kcal over your 2,000 kcal target."));
    expect(texts, contains('Water goal reached (3.1 L).'));
    expect(texts, contains('Workout logged: Upper A (Hevy).'));
    expect(texts.where((t) => t.contains('Planned workout')), isEmpty);
  });

  test('calendar connected but failed, or no events left', () {
    final failed = buildDailySummary(
      SummaryInput(
        now: now,
        calendar: const CalendarFact(connected: true, error: 'timeout'),
      ),
    );
    expect(failed.unavailable, contains('Calendar (could not load)'));
    final empty = buildDailySummary(
      SummaryInput(
        now: now,
        calendar: CalendarFact(
          connected: true,
          events: [EventFact(title: 'Past', start: DateTime(2026, 10, 25, 8))],
        ),
      ),
    );
    expect(empty.lines.single.text, 'No more timed calendar events today.');
  });
}
