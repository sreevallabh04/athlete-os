import 'package:athlete_os/features/health/domain/steps_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 06:30 → 22:30 (profile defaults).
  const day = WakingWindow(wakeMinutes: 390, sleepMinutes: 1350);
  // Night-shift: awake 22:00 → 06:00.
  const overnight = WakingWindow(wakeMinutes: 1320, sleepMinutes: 360);

  group('stepsProgress', () {
    test('below goal', () {
      final p = stepsProgress(6500, 10000);
      expect(p.remaining, 3500);
      expect(p.percent, 65);
      expect(p.goalMet, isFalse);
    });

    test('goal met exactly', () {
      final p = stepsProgress(10000, 10000);
      expect(p.remaining, 0);
      expect(p.percent, 100);
      expect(p.goalMet, isTrue);
    });

    test('over goal: remaining clamps to 0, percent exceeds 100', () {
      final p = stepsProgress(12500, 10000);
      expect(p.remaining, 0);
      expect(p.percent, 125);
      expect(p.fraction, closeTo(1.25, 1e-9));
    });

    test('zero goal means no goal, no division by zero', () {
      final p = stepsProgress(4000, 0);
      expect(p.hasGoal, isFalse);
      expect(p.remaining, 0);
      expect(p.fraction, 0);
      expect(p.goalMet, isFalse);
    });

    test('negative steps are treated as zero', () {
      expect(stepsProgress(-5, 100).remaining, 100);
    });
  });

  group('WakingWindow', () {
    test('same-day schedule', () {
      expect(day.lengthMinutes, 960);
      expect(day.isAwake(DateTime(2026, 10, 25, 6)), isFalse);
      expect(day.isBeforeWake(DateTime(2026, 10, 25, 6)), isTrue);
      expect(day.remainingMinutes(DateTime(2026, 10, 25, 6)), 960);
      expect(day.remainingMinutes(DateTime(2026, 10, 25, 14, 30)), 480);
      expect(day.elapsedFraction(DateTime(2026, 10, 25, 14, 30)), 0.5);
      expect(day.remainingMinutes(DateTime(2026, 10, 25, 23)), 0);
      expect(day.elapsedFraction(DateTime(2026, 10, 25, 23)), 1.0);
    });

    test('overnight schedule crosses midnight', () {
      expect(overnight.isOvernight, isTrue);
      expect(overnight.lengthMinutes, 480);
      // 23:00 → 7 hours left until 06:00.
      expect(overnight.isAwake(DateTime(2026, 10, 25, 23)), isTrue);
      expect(overnight.remainingMinutes(DateTime(2026, 10, 25, 23)), 420);
      // 02:00 (after midnight) → 4 hours left.
      expect(overnight.remainingMinutes(DateTime(2026, 10, 26, 2)), 240);
      expect(overnight.elapsedFraction(DateTime(2026, 10, 26, 2)), 0.5);
      // 12:00 → asleep, period done.
      expect(overnight.isAwake(DateTime(2026, 10, 26, 12)), isFalse);
      expect(overnight.remainingMinutes(DateTime(2026, 10, 26, 12)), 0);
      expect(overnight.elapsedFraction(DateTime(2026, 10, 26, 12)), 1.0);
    });
  });

  group('stepsPerRemainingHour', () {
    test('divides remaining steps by remaining waking hours', () {
      // 14:30 → 8 h left; 4000 remaining → 500/h.
      final v = stepsPerRemainingHour(
        steps: 6000,
        goal: 10000,
        now: DateTime(2026, 10, 25, 14, 30),
        window: day,
      );
      expect(v, closeTo(500, 1e-9));
    });

    test('before wake time uses the whole waking day', () {
      final v = stepsPerRemainingHour(
        steps: 0,
        goal: 9600,
        now: DateTime(2026, 10, 25, 5),
        window: day,
      );
      expect(v, closeTo(600, 1e-9)); // 9600 / 16 h
    });

    test('none when goal met, no goal, or after bedtime', () {
      final at = DateTime(2026, 10, 25, 12);
      expect(
        stepsPerRemainingHour(steps: 10000, goal: 10000, now: at, window: day),
        isNull,
      );
      expect(
        stepsPerRemainingHour(steps: 100, goal: 0, now: at, window: day),
        isNull,
      );
      expect(
        stepsPerRemainingHour(
          steps: 100,
          goal: 10000,
          now: DateTime(2026, 10, 25, 23, 15),
          window: day,
        ),
        isNull,
      );
    });

    test('overnight window after midnight', () {
      final v = stepsPerRemainingHour(
        steps: 2000,
        goal: 6000,
        now: DateTime(2026, 10, 26, 2),
        window: overnight,
      );
      expect(v, closeTo(1000, 1e-9)); // 4000 / 4 h
    });

    test('caps the divisor at 15 minutes right before bedtime', () {
      final v = stepsPerRemainingHour(
        steps: 9000,
        goal: 10000,
        now: DateTime(2026, 10, 25, 22, 25),
        window: day,
      );
      expect(v, closeTo(4000, 1e-9)); // 1000 / 0.25 h
    });
  });

  group('checkPace', () {
    test('behind when below 70% of expected', () {
      // 14:30 → 50% of day → expected 5000; 3000 < 3500 → behind.
      final c = checkPace(
        steps: 3000,
        goal: 10000,
        now: DateTime(2026, 10, 25, 14, 30),
        window: day,
      );
      expect(c.expectedByNow, 5000);
      expect(c.behind, isTrue);
      expect(c.ratio, closeTo(0.6, 1e-9));
    });

    test('not behind at or above 70% of expected', () {
      final c = checkPace(
        steps: 3500,
        goal: 10000,
        now: DateTime(2026, 10, 25, 14, 30),
        window: day,
      );
      expect(c.behind, isFalse);
    });

    test('never behind before wake, in grace hour, after bedtime or met', () {
      bool behind(int steps, DateTime at) =>
          checkPace(steps: steps, goal: 10000, now: at, window: day).behind;
      expect(behind(0, DateTime(2026, 10, 25, 6)), isFalse);
      expect(behind(0, DateTime(2026, 10, 25, 7)), isFalse); // grace
      expect(behind(0, DateTime(2026, 10, 25, 7, 45)), isTrue);
      expect(behind(0, DateTime(2026, 10, 25, 23)), isFalse);
      expect(behind(10000, DateTime(2026, 10, 25, 20)), isFalse);
      expect(
        checkPace(
          steps: 0,
          goal: 0,
          now: DateTime(2026, 10, 25, 20),
          window: day,
        ).behind,
        isFalse,
      );
    });
  });

  group('stepsStats', () {
    test('averages ignore days without data and count goal days', () {
      final s = stepsStats({
        '2026-10-19': 12000,
        '2026-10-20': null,
        '2026-10-21': 8000,
        '2026-10-22': 10000,
      }, 10000);
      expect(s.days, 4);
      expect(s.daysWithData, 3);
      expect(s.average, 10000);
      expect(s.goalHitDays, 2);
      expect(s.total, 30000);
    });

    test('no data → null average', () {
      expect(stepsStats({'2026-10-19': null}, 10000).average, isNull);
    });
  });

  group('resolveDaySteps (manual vs Health Connect)', () {
    test('Health Connect wins and manual is kept as overridden', () {
      final d = resolveDaySteps(healthConnect: 7000, manual: 9000)!;
      expect(d.steps, 7000);
      expect(d.origin, 'health_connect');
      expect(d.overriddenManual, 9000);
    });

    test('manual used when there is no Health Connect value', () {
      final d = resolveDaySteps(manual: 4200)!;
      expect(d.steps, 4200);
      expect(d.isManual, isTrue);
      expect(d.overriddenManual, isNull);
    });

    test('null when neither exists', () {
      expect(resolveDaySteps(), isNull);
    });
  });
}
