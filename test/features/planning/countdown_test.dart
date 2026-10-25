import 'package:athlete_os/features/planning/domain/countdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  CountdownResult c(
    String event,
    String tz,
    DateTime now, {
    String? prep,
    DateTime? created,
  }) => CompetitionCountdown.compute(
    eventDate: event,
    tzName: tz,
    now: now,
    prepStartDate: prep,
    createdAt: created,
  );

  group('basic phases', () {
    test('same day is "today"', () {
      final r = c('2026-10-25', 'UTC', DateTime.utc(2026, 10, 25, 23, 59));
      expect(r.daysRemaining, 0);
      expect(r.phase, CountdownPhase.today);
      expect(r.weeksAndDaysLabel, 'Today');
      expect(r.headline('Classic'), 'Classic is today');
    });

    test('upcoming: whole weeks', () {
      final r = c('2026-12-06', 'UTC', DateTime.utc(2026, 10, 25, 12));
      expect(r.daysRemaining, 42);
      expect(r.phase, CountdownPhase.upcoming);
      expect(r.weeks, 6);
      expect(r.remainderDays, 0);
      expect(r.weeksAndDaysLabel, '6 weeks');
      expect(r.headline('Classic'), '42 days to Classic');
    });

    test('upcoming: weeks and days, singulars', () {
      expect(
        c('2026-12-09', 'UTC', DateTime.utc(2026, 10, 25)).weeksAndDaysLabel,
        '6 weeks 3 days',
      );
      expect(
        c('2026-11-02', 'UTC', DateTime.utc(2026, 10, 25)).weeksAndDaysLabel,
        '1 week 1 day',
      );
      expect(
        c('2026-10-29', 'UTC', DateTime.utc(2026, 10, 25)).weeksAndDaysLabel,
        '4 days',
      );
      expect(
        c('2026-10-26', 'UTC', DateTime.utc(2026, 10, 25)).headline('X'),
        '1 day to X',
      );
    });

    test('past dates report days since', () {
      final r = c('2026-10-20', 'UTC', DateTime.utc(2026, 10, 25, 8));
      expect(r.daysRemaining, -5);
      expect(r.phase, CountdownPhase.past);
      expect(r.daysSince, 5);
      expect(r.weeks, 0);
      expect(r.weeksAndDaysLabel, '5 days ago');
      expect(r.headline('Show'), 'Show was 5 days ago');
    });
  });

  group('timezones', () {
    test('device tz differs from event tz near midnight', () {
      // 19:00Z = 00:30 next day in Kolkata, 12:00 same day in Los Angeles.
      final now = DateTime.utc(2026, 10, 25, 19);
      final india = c('2026-10-30', 'Asia/Kolkata', now);
      final la = c('2026-10-30', 'America/Los_Angeles', now);
      expect(india.todayInEventTz.key, '2026-10-26');
      expect(india.daysRemaining, 4);
      expect(la.todayInEventTz.key, '2026-10-25');
      expect(la.daysRemaining, 5);
    });

    test('one minute before midnight in the event tz', () {
      // 18:29Z = 23:59 IST.
      final r = c(
        '2026-10-30',
        'Asia/Kolkata',
        DateTime.utc(2026, 10, 25, 18, 29),
      );
      expect(r.todayInEventTz.key, '2026-10-25');
      expect(r.daysRemaining, 5);
      final after = c(
        '2026-10-30',
        'Asia/Kolkata',
        DateTime.utc(2026, 10, 25, 18, 30),
      );
      expect(after.daysRemaining, 4);
    });

    test('DST spring-forward day does not cause an off-by-one', () {
      // US DST starts 2026-03-08 at 02:00 local (a 23-hour day).
      expect(
        c(
          '2026-03-09',
          'America/New_York',
          DateTime.utc(2026, 3, 7, 12),
        ).daysRemaining,
        2,
      );
      // Before (01:30 EST) and after (03:30 EDT) the jump on the same day.
      expect(
        c(
          '2026-03-10',
          'America/New_York',
          DateTime.utc(2026, 3, 8, 6, 30),
        ).daysRemaining,
        2,
      );
      expect(
        c(
          '2026-03-10',
          'America/New_York',
          DateTime.utc(2026, 3, 8, 7, 30),
        ).daysRemaining,
        2,
      );
    });

    test('DST fall-back day (25-hour day) counts as one calendar day', () {
      // UK clocks go back on 2026-10-25 at 02:00 BST (01:00Z).
      final early = c(
        '2026-10-26',
        'Europe/London',
        DateTime.utc(2026, 10, 24, 23, 30), // 00:30 BST on the 25th
      );
      final late = c(
        '2026-10-26',
        'Europe/London',
        DateTime.utc(2026, 10, 25, 23, 30), // 23:30 GMT on the 25th
      );
      expect(early.todayInEventTz.key, '2026-10-25');
      expect(early.daysRemaining, 1);
      expect(late.todayInEventTz.key, '2026-10-25');
      expect(late.daysRemaining, 1);
    });

    test('invalid timezone falls back to the device timezone', () {
      final now = DateTime(2026, 10, 25, 12); // device-local noon
      final r = c('2026-10-27', 'Mars/Olympus_Mons', now);
      expect(r.usedFallbackTz, isTrue);
      expect(r.effectiveTzName, isNull);
      expect(r.todayInEventTz.key, '2026-10-25');
      expect(r.daysRemaining, 2);
      expect(isValidTimeZone('Mars/Olympus_Mons'), isFalse);
      expect(isValidTimeZone('Asia/Kolkata'), isTrue);
    });
  });

  group('calendar edge cases', () {
    test('leap day', () {
      expect(
        c('2028-02-29', 'UTC', DateTime.utc(2028, 2, 27, 9)).daysRemaining,
        2,
      );
      expect(
        c('2028-03-01', 'UTC', DateTime.utc(2028, 2, 28, 9)).daysRemaining,
        2,
      );
      expect(
        c('2027-03-01', 'UTC', DateTime.utc(2027, 2, 28, 9)).daysRemaining,
        1,
      );
      expect(CalendarDate.tryParse('2028-02-29'), isNotNull);
      expect(CalendarDate.tryParse('2027-02-29'), isNull);
    });

    test('year boundary', () {
      expect(
        c('2027-01-01', 'UTC', DateTime.utc(2026, 12, 31, 23)).daysRemaining,
        1,
      );
    });

    test('invalid event date throws', () {
      expect(
        () => c('2026-13-01', 'UTC', DateTime.utc(2026)),
        throwsArgumentError,
      );
      expect(
        () => c('next week', 'UTC', DateTime.utc(2026)),
        throwsArgumentError,
      );
    });
  });

  group('progress', () {
    test('from createdAt to event', () {
      final r = c(
        '2026-11-30',
        'UTC',
        DateTime.utc(2026, 10, 31, 10),
        created: DateTime.utc(2026, 10, 1, 12),
      );
      expect(r.totalPrepDays, 60);
      expect(r.progress, closeTo(0.5, 1e-9));
    });

    test('user-set prep start overrides createdAt', () {
      final r = c(
        '2026-11-30',
        'UTC',
        DateTime.utc(2026, 10, 31, 10),
        created: DateTime.utc(2026, 10, 1, 12),
        prep: '2026-10-21',
      );
      expect(r.prepStart!.key, '2026-10-21');
      expect(r.progress, closeTo(0.25, 1e-9));
    });

    test('clamps to 0..1 and is null without a start', () {
      expect(
        c(
          '2026-10-20',
          'UTC',
          DateTime.utc(2026, 10, 25),
          prep: '2026-09-01',
        ).progress,
        1.0,
      );
      expect(
        c(
          '2026-12-20',
          'UTC',
          DateTime.utc(2026, 10, 25),
          prep: '2026-11-01',
        ).progress,
        0.0,
      );
      expect(
        c('2026-12-20', 'UTC', DateTime.utc(2026, 10, 25)).progress,
        isNull,
      );
    });

    test('createdAt is interpreted in the event timezone', () {
      // 20:00Z on Oct 1 is Oct 2 in Kolkata.
      final r = c(
        '2026-10-12',
        'Asia/Kolkata',
        DateTime.utc(2026, 10, 7, 0),
        created: DateTime.utc(2026, 10, 1, 20),
      );
      expect(r.prepStart!.key, '2026-10-02');
      expect(r.totalPrepDays, 10);
      expect(r.progress, closeTo(0.5, 1e-9));
    });
  });
}
