import 'package:athlete_os/core/domain/free_slots.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:athlete_os/features/life/domain/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

String hm(tz.TZDateTime t) => formatMinutes(t.hour * 60 + t.minute);

void main() {
  late tz.Location utc;
  setUpAll(() {
    tzdata.initializeTimeZones();
    utc = tz.getLocation('UTC');
  });

  group('interval reminders', () {
    test('stay inside the wake window', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const IntervalPattern(120),
        now: now,
        days: 1,
        wakeMinutes: 7 * 60,
        sleepMinutes: 22 * 60,
      );
      expect(times.map(hm), [
        '09:00',
        '11:00',
        '13:00',
        '15:00',
        '17:00',
        '19:00',
        '21:00',
      ]);
    });

    test('never more than max per day (earliest kept)', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const IntervalPattern(60),
        now: now,
        days: 3,
        wakeMinutes: 6 * 60,
        sleepMinutes: 23 * 60,
        maxPerDay: 4,
      );
      expect(times.length, 12);
      expect(times.take(4).map(hm), ['07:00', '08:00', '09:00', '10:00']);
    });

    test('overnight quiet hours (21:00–07:00) are respected', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const IntervalPattern(60),
        now: now,
        days: 1,
        wakeMinutes: 5 * 60,
        sleepMinutes: 23 * 60 + 30,
        quietHours: const QuietHours(21 * 60, 7 * 60),
      );
      expect(times.first.hour, 7);
      expect(times.last.hour, 20);
      for (final t in times) {
        expect(t.hour >= 7 && t.hour < 21, isTrue, reason: '$t');
      }
    });

    test('a sleep time after midnight extends the window into the night', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const IntervalPattern(120),
        now: now,
        days: 1,
        wakeMinutes: 16 * 60,
        sleepMinutes: 60,
      );
      expect(times.map(hm), ['18:00', '20:00', '22:00', '00:00']);
      expect(times.last.day, 27);
    });

    test('busy blocks drop interval reminders', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final busy = [
        TimeInterval(
          DateTime.utc(2026, 10, 26, 10, 30),
          DateTime.utc(2026, 10, 26, 11, 30),
        ),
      ];
      final times = planReminderTimes(
        pattern: const IntervalPattern(120),
        now: now,
        days: 1,
        wakeMinutes: 7 * 60,
        sleepMinutes: 14 * 60,
        busy: busy,
      );
      expect(times.map(hm), ['09:00', '13:00']);
    });

    test('only instants after now are returned', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26, 12, 30);
      final times = planReminderTimes(
        pattern: const IntervalPattern(120),
        now: now,
        days: 1,
        wakeMinutes: 7 * 60,
        sleepMinutes: 22 * 60,
      );
      expect(times.first.hour, 13);
    });
  });

  group('fixed reminders', () {
    test('are moved to the end of a busy block when short', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final busy = [
        TimeInterval(
          DateTime.utc(2026, 10, 26, 10, 30),
          DateTime.utc(2026, 10, 26, 11, 30),
        ),
        // Adjacent block merges with the first.
        TimeInterval(
          DateTime.utc(2026, 10, 26, 11, 30),
          DateTime.utc(2026, 10, 26, 12),
        ),
      ];
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([11 * 60]),
        now: now,
        days: 1,
        busy: busy,
      );
      expect(times.map(hm), ['12:00']);
    });

    test('keep their time when the busy block is too long', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final busy = [
        TimeInterval(
          DateTime.utc(2026, 10, 26, 9),
          DateTime.utc(2026, 10, 26, 17),
        ),
      ];
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([11 * 60]),
        now: now,
        days: 1,
        busy: busy,
      );
      expect(times.map(hm), ['11:00']);
    });

    test('are de-duplicated and follow the days mask', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26); // Monday
      final times = planReminderTimes(
        pattern: FixedTimesPattern(const [
          540,
          540,
        ], daysMask: weekdayBit(1) | weekdayBit(3)),
        now: now,
        days: 7,
      );
      expect(times.map((t) => t.weekday), [1, 3]);
    });

    test('are suppressed in quiet hours', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([23 * 60, 12 * 60]),
        now: now,
        days: 1,
        quietHours: const QuietHours(22 * 60, 7 * 60),
      );
      expect(times.map(hm), ['12:00']);
    });

    test('dated reminders fire only on their dates', () {
      final now = tz.TZDateTime(utc, 2026, 10, 26);
      final times = planReminderTimes(
        pattern: const DatesPattern({'2026-11-02', '2026-12-31'}, 480),
        now: now,
        days: 30,
      );
      expect(times.length, 1);
      expect(times.single.day, 2);
      expect(times.single.hour, 8);
    });
  });

  group('DST', () {
    test('a 09:00 reminder stays at 09:00 local across the October change', () {
      final london = tz.getLocation('Europe/London');
      // Clocks go back at 02:00 BST on Sunday 25 Oct 2026.
      final now = tz.TZDateTime(london, 2026, 10, 24);
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([9 * 60]),
        now: now,
        days: 3,
      );
      expect(times.map(hm), ['09:00', '09:00', '09:00']);
      expect(times.map((t) => t.toUtc().hour), [8, 9, 9]);
    });

    test('a time inside the spring-forward gap fires once, after the gap', () {
      final ny = tz.getLocation('America/New_York');
      // 2026-03-08 02:00 → 03:00 in New York.
      final now = tz.TZDateTime(ny, 2026, 3, 7, 12);
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([2 * 60 + 30]),
        now: now,
        days: 3,
      );
      final onDstDay = times.where((t) => t.day == 8).toList();
      expect(onDstDay.length, 1);
      expect(onDstDay.single.hour, 3);
      // 7th 02:30 is already past; 8th (shifted) and 9th remain.
      expect(times.length, 2);
      expect(hm(times.last), '02:30');
    });

    test('an ambiguous fall-back time is scheduled once', () {
      final ny = tz.getLocation('America/New_York');
      // 2026-11-01 01:00–02:00 happens twice in New York.
      final now = tz.TZDateTime(ny, 2026, 10, 31, 12);
      final times = planReminderTimes(
        pattern: const FixedTimesPattern([90]),
        now: now,
        days: 2,
      );
      expect(times.where((t) => t.day == 1).length, 1);
    });

    test('interval reminders keep wall-clock times on DST day', () {
      final london = tz.getLocation('Europe/London');
      final now = tz.TZDateTime(london, 2026, 10, 25);
      final times = planReminderTimes(
        pattern: const IntervalPattern(180),
        now: now,
        days: 1,
        wakeMinutes: 6 * 60,
        sleepMinutes: 22 * 60,
      );
      expect(times.map(hm), ['09:00', '12:00', '15:00', '18:00', '21:00']);
    });
  });

  test('QuietHours parsing and containment', () {
    const q = QuietHours(22 * 60, 7 * 60);
    expect(q.isOvernight, isTrue);
    expect(q.contains(23 * 60), isTrue);
    expect(q.contains(3 * 60), isTrue);
    expect(q.contains(7 * 60), isFalse);
    expect(q.contains(12 * 60), isFalse);
    const day = QuietHours(13 * 60, 14 * 60);
    expect(day.contains(13 * 60 + 30), isTrue);
    expect(day.contains(14 * 60), isFalse);
    expect(QuietHours.fromJson({'start': 1320, 'end': 420})?.start, 1320);
    expect(QuietHours.fromJson({'start': 60, 'end': 60}), isNull);
    expect(QuietHours.fromJson('nope'), isNull);
  });
}
