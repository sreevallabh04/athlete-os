import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/planning/data/planning_repository.dart';
import 'package:athlete_os/features/planning/domain/habit_schedule.dart';
import 'package:athlete_os/features/planning/domain/task_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  // 2026-10-26 is a Monday.
  const mon = '2026-10-26';
  const wed = '2026-10-28';
  const sun = '2026-11-01';

  group('habit due-today logic', () {
    test('daily habits are due every day until done', () {
      const h = HabitSpec(id: 'h', name: 'Walk');
      expect(habitStateOn(h, mon, const []), HabitDayState.due);
      expect(
        habitStateOn(h, mon, const [HabitMark('h', mon, 'done')]),
        HabitDayState.done,
      );
      expect(
        habitStateOn(h, mon, const [HabitMark('h', mon, 'skipped')]),
        HabitDayState.skipped,
      );
      // A completion for another habit or day doesn't count.
      expect(
        habitStateOn(h, mon, const [
          HabitMark('other', mon, 'done'),
          HabitMark('h', wed, 'done'),
        ]),
        HabitDayState.due,
      );
    });

    test('custom days mask: bit0 = Monday ... bit6 = Sunday', () {
      const monWed = HabitSpec(
        id: 'p',
        name: 'Posing',
        scheduleType: 'custom',
        daysMask: 1 | 4, // Mon + Wed
      );
      expect(isScheduledOn(monWed, mon), isTrue);
      expect(isScheduledOn(monWed, '2026-10-27'), isFalse); // Tue
      expect(isScheduledOn(monWed, wed), isTrue);
      expect(
        habitStateOn(monWed, '2026-10-27', const []),
        HabitDayState.notScheduled,
      );
      const sundayOnly = HabitSpec(
        id: 's',
        name: 'Meal prep',
        scheduleType: 'custom',
        daysMask: 64,
      );
      expect(isScheduledOn(sundayOnly, sun), isTrue);
      expect(isScheduledOn(sundayOnly, mon), isFalse);
    });

    test('weekly habits stop being due once the weekly target is met', () {
      const h = HabitSpec(
        id: 'w',
        name: 'Long run',
        scheduleType: 'weekly',
        targetPerWeek: 2,
      );
      const marks = [
        HabitMark('w', mon, 'done'),
        HabitMark('w', '2026-10-27', 'done'),
      ];
      expect(habitStateOn(h, wed, marks), HabitDayState.weeklyTargetMet);
      // Only one done earlier -> still due.
      expect(habitStateOn(h, wed, marks.take(1)), HabitDayState.due);
      // Previous week's completions don't count toward this week.
      expect(
        habitStateOn(h, mon, const [
          HabitMark('w', '2026-10-24', 'done'),
          HabitMark('w', '2026-10-25', 'done'),
        ]),
        HabitDayState.due,
      );
    });

    test('archived habits are never due; tally counts done vs remaining', () {
      const habits = [
        HabitSpec(id: 'a', name: 'A'),
        HabitSpec(id: 'b', name: 'B'),
        HabitSpec(id: 'c', name: 'C', archived: true),
        HabitSpec(id: 'd', name: 'D', scheduleType: 'custom', daysMask: 2),
      ];
      final tally = tallyHabits(habits, mon, const [
        HabitMark('a', mon, 'done'),
      ]);
      expect(tally.done, 1);
      expect(tally.remaining, 1);
      expect(tally.total, 2);
    });

    test('completion rate over a range', () {
      const habits = [
        HabitSpec(id: 'a', name: 'Daily'),
        HabitSpec(
          id: 'w',
          name: 'Weekly',
          scheduleType: 'weekly',
          targetPerWeek: 3,
        ),
      ];
      final days = LocalDates.range(mon, sun);
      final r = habitCompletion(habits, days, const [
        HabitMark('a', mon, 'done'),
        HabitMark('a', wed, 'done'),
        HabitMark('a', '2026-10-27', 'skipped'), // skipped is not done
        HabitMark('w', mon, 'done'),
        HabitMark('w', wed, 'done'),
        HabitMark('w', sun, 'done'),
        HabitMark('w', '2026-10-30', 'done'), // over target, capped
      ]);
      expect(r.expected, 7 + 3);
      expect(r.completed, 2 + 3);
    });
  });

  group('task carryover', () {
    const y = '2026-10-24';
    const t = '2026-10-25';
    test(
      'candidates are yesterday\'s undone, non-deleted tasks by priority',
      () {
        final tasks = [
          const TaskItem(id: '1', title: 'Done', localDate: y, done: true),
          const TaskItem(id: '2', title: 'Low', localDate: y, priority: 3),
          const TaskItem(
            id: '3',
            title: 'Deleted',
            localDate: y,
            deleted: true,
          ),
          const TaskItem(id: '4', title: 'High', localDate: y, priority: 1),
          const TaskItem(id: '5', title: 'Today', localDate: t),
        ];
        final c = carryoverCandidates(tasks, previousDate: y);
        expect(c.map((e) => e.title), ['High', 'Low']);
      },
    );

    test('manual order wins, then priority; top 3 puts undone first', () {
      final tasks = [
        const TaskItem(id: 'a', title: 'A', localDate: t, priority: 3),
        const TaskItem(
          id: 'b',
          title: 'B',
          localDate: t,
          priority: 1,
          done: true,
        ),
        const TaskItem(id: 'c', title: 'C', localDate: t, priority: 2),
        const TaskItem(id: 'd', title: 'D', localDate: t, priority: 1),
      ];
      expect(orderTasks(tasks, const []).map((e) => e.id), [
        'b',
        'd',
        'c',
        'a',
      ]);
      expect(orderTasks(tasks, const ['a', 'c']).map((e) => e.id), [
        'a',
        'c',
        'b',
        'd',
      ]);
      expect(topPriorities(tasks, const []).map((e) => e.id), ['d', 'c', 'a']);
    });

    test(
      'repository carryOver moves only chosen undone tasks and records origin',
      () async {
        final db = newTestDb();
        addTearDown(db.close);
        final repo = PlanningRepository(
          db,
          SettingsRepository(db),
          FixedClock(DateTime(2026, 10, 25, 8)),
        );
        final a = await repo.addTask(
          title: 'Finish report',
          date: y,
          priority: 1,
        );
        final b = await repo.addTask(title: 'Call physio', date: y);
        final c = await repo.addTask(title: 'Done thing', date: y);
        await repo.setTaskDone(c, true);

        final moved = await repo.carryOver([a, c], t);
        expect(moved, 1);
        final today = await repo.tasksOn(t);
        expect(today.single.id, a);
        expect(today.single.carriedFromDate, y);
        final yesterday = await repo.tasksOn(y);
        expect(yesterday.map((e) => e.id).toSet(), {b, c});

        // Carrying again keeps the original origin date.
        final moved2 = await repo.carryOver([a], '2026-10-26');
        expect(moved2, 1);
        final row = await (db.select(
          db.tasks,
        )..where((x) => x.id.equals(a))).getSingle();
        expect(row.localDate, '2026-10-26');
        expect(row.carriedFromDate, y);
      },
    );
  });
}
