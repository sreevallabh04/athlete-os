import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/features/life/domain/habit_engine.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:flutter_test/flutter_test.dart';

// 2026-10-25 is a Sunday; its ISO week starts Monday 2026-10-19.
const today = '2026-10-25';
String ago(int n) => LocalDates.addDays(today, -n);

Map<String, DayMark> done(Iterable<String> dates) => {
  for (final d in dates) d: const DayMark.done(),
};

void main() {
  group('daily streaks', () {
    const daily = HabitSchedule.daily();

    test('consecutive done days including today', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: done([today, ago(1), ago(2)]),
        today: today,
        startDate: ago(30),
      );
      expect(r.current, 3);
      expect(r.best, 3);
      expect(r.unit, StreakUnit.days);
    });

    test('today not yet done does not break the streak', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: done([ago(1), ago(2)]),
        today: today,
        startDate: ago(30),
      );
      expect(r.current, 2);
    });

    test('a missed scheduled day breaks the streak; best is kept', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: done([ago(1), ago(3), ago(4), ago(5)]),
        today: today,
        startDate: ago(30),
      );
      expect(r.current, 1);
      expect(r.best, 3);
    });

    test('skipped days are neutral: neither extend nor break', () {
      final marks = {
        ...done([ago(1), ago(3)]),
        ago(2): const DayMark.skipped(),
      };
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: marks,
        today: today,
        startDate: ago(3),
      );
      expect(r.current, 2);
      expect(r.best, 2);
    });

    test('days before the habit started never count as missed', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: done([ago(1), ago(2)]),
        today: today,
        startDate: ago(2),
      );
      expect(r.current, 2);
      expect(r.best, 2);
    });

    test('back-filled marks before the start date extend the history', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: done([ago(1), ago(2), ago(3)]),
        today: today,
        startDate: ago(1),
      );
      expect(r.current, 3);
    });

    test('no marks at all → zero', () {
      final r = HabitEngine.streaks(
        schedule: daily,
        marks: const {},
        today: today,
        startDate: ago(10),
      );
      expect(r.current, 0);
      expect(r.best, 0);
    });
  });

  group('custom days', () {
    // Mon, Wed, Fri.
    final mwf = HabitSchedule.custom(
      weekdayBit(1) | weekdayBit(3) | weekdayBit(5),
    );

    test('only scheduled days count; unscheduled gaps are ignored', () {
      // Fri 23, Wed 21, Mon 19 done; today is Sunday (unscheduled).
      final r = HabitEngine.streaks(
        schedule: mwf,
        marks: done(['2026-10-23', '2026-10-21', '2026-10-19']),
        today: today,
        startDate: '2026-10-01',
      );
      expect(r.current, 3);
    });

    test('missing a scheduled day breaks it', () {
      final r = HabitEngine.streaks(
        schedule: mwf,
        marks: done(['2026-10-23', '2026-10-19']),
        today: today,
        startDate: '2026-10-01',
      );
      expect(r.current, 1);
    });

    test('isDueOn follows the days mask', () {
      expect(HabitEngine.isDueOn(mwf, '2026-10-19'), isTrue); // Mon
      expect(HabitEngine.isDueOn(mwf, '2026-10-20'), isFalse); // Tue
      expect(HabitEngine.isDueOn(mwf, today), isFalse); // Sun
      expect(
        HabitEngine.isDueOn(mwf, '2026-10-19', startDate: '2026-10-20'),
        isFalse,
      );
    });
  });

  group('weekly targets (ISO weeks)', () {
    const three = HabitSchedule.weekly(3);

    test('met weeks extend, missed week breaks, current week is neutral', () {
      final marks = done([
        // current week (in progress, 2 of 3) – neutral
        '2026-10-20', '2026-10-22',
        // week of 12th – met
        '2026-10-12', '2026-10-14', '2026-10-16',
        // week of 5th – missed (1 of 3)
        '2026-10-07',
        // week of 28 Sep – met
        '2026-09-28', '2026-09-30', '2026-10-02',
        // week of 21 Sep – met (4)
        '2026-09-21', '2026-09-22', '2026-09-23', '2026-09-24',
      ]);
      final r = HabitEngine.streaks(
        schedule: three,
        marks: marks,
        today: today,
        startDate: '2026-09-21',
      );
      expect(r.unit, StreakUnit.weeks);
      expect(r.current, 1);
      expect(r.best, 2);
    });

    test('current week counts once the target is met', () {
      final r = HabitEngine.streaks(
        schedule: three,
        marks: done(['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-13']),
        today: today,
        startDate: '2026-10-19',
      );
      expect(r.current, 1);
    });

    test('skips covering the shortfall keep the week neutral', () {
      final marks = {
        ...done(['2026-10-12', '2026-10-13']),
        '2026-10-14': const DayMark.skipped(),
        ...done(['2026-10-05', '2026-10-06', '2026-10-07']),
      };
      final r = HabitEngine.streaks(
        schedule: three,
        marks: marks,
        today: today,
        startDate: '2026-10-05',
      );
      expect(r.current, 1); // week of 5th met; week of 12th neutral
    });

    test('partial first week below target is neutral', () {
      // Created Thursday 15th, done once that week; next week met.
      final r = HabitEngine.streaks(
        schedule: three,
        marks: done(['2026-10-16', '2026-10-19', '2026-10-20', '2026-10-21']),
        today: today,
        startDate: '2026-10-15',
      );
      expect(r.current, 1);
      expect(r.best, 1);
    });

    test('isDueOn hides the habit once this week\'s target is reached', () {
      const two = HabitSchedule.weekly(2);
      final marks = done(['2026-10-19', '2026-10-20']);
      expect(HabitEngine.isDueOn(two, '2026-10-21', marks: marks), isFalse);
      expect(HabitEngine.isDueOn(two, '2026-10-19', marks: marks), isTrue);
      expect(HabitEngine.isDueOn(two, '2026-10-21'), isTrue);
    });

    test('week progress uses target minus skips', () {
      final marks = {
        ...done(['2026-10-19']),
        '2026-10-20': const DayMark.skipped(),
      };
      final p = HabitEngine.weekProgress(
        schedule: three,
        marks: marks,
        today: today,
        startDate: '2026-10-01',
      );
      expect(p.done, 1);
      expect(p.due, 2);
      expect(p.rate, 0.5);
    });
  });

  group('completion %', () {
    test('done / due with skipped excluded and unfinished today ignored', () {
      final marks = {
        ...done(['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-22']),
        '2026-10-23': const DayMark.skipped(),
        // 24th missing, today (25th) not yet done
      };
      final p = HabitEngine.weekProgress(
        schedule: const HabitSchedule.daily(),
        marks: marks,
        today: today,
        startDate: '2026-10-01',
      );
      expect(p.done, 4);
      expect(p.due, 5);
      expect(p.skipped, 1);
      expect(p.rate, closeTo(0.8, 1e-9));
    });

    test('rate is null when nothing was due', () {
      final p = HabitEngine.weekProgress(
        schedule: const HabitSchedule.daily(),
        marks: const {},
        today: '2026-10-19',
        startDate: '2026-10-19',
      );
      expect(p.due, 0);
      expect(p.rate, isNull);
    });

    test('weekly habit: unfinished current week is not judged in ranges', () {
      final c = HabitEngine.completion(
        schedule: const HabitSchedule.weekly(3),
        marks: done(['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-20']),
        from: '2026-10-12',
        to: today,
        today: today,
        startDate: '2026-10-12',
      );
      expect(c.done, 3);
      expect(c.due, 3);
    });
  });

  group('auto marks and dependencies', () {
    test('manual status always wins over automatic completion', () {
      final m = mergeMarks(
        {'2026-10-24': HabitStatus.skipped},
        {'2026-10-24', '2026-10-25'},
      );
      expect(m['2026-10-24'], const DayMark.skipped());
      expect(m['2026-10-25'], const DayMark.done(auto: true));
    });

    test('dependent habit is suggested once its prerequisite is done', () {
      final next = HabitEngine.suggestedNext(const [
        HabitDependencyView(
          id: 'a',
          dependsOnId: null,
          dueToday: true,
          todayMark: DayMark.done(),
        ),
        HabitDependencyView(
          id: 'b',
          dependsOnId: 'a',
          dueToday: true,
          todayMark: null,
        ),
        HabitDependencyView(
          id: 'c',
          dependsOnId: 'b',
          dueToday: true,
          todayMark: null,
        ),
      ]);
      expect(next, {'b'});
    });
  });

  test('days mask helpers', () {
    expect(describeDaysMask(allDaysMask), 'Every day');
    expect(describeDaysMask(0x1F), 'Weekdays');
    expect(describeDaysMask(weekdayBit(1) | weekdayBit(3)), 'Mon, Wed');
    expect(parseReminderTimes([450, 450, -1, 2000, 60]), [60, 450]);
    expect(formatMinutes(450), '07:30');
  });
}
