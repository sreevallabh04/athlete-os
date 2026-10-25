import 'package:athlete_os/features/train/domain/strength_analytics.dart';
import 'package:athlete_os/features/train/domain/strength_models.dart';
import 'package:flutter_test/flutter_test.dart';

StrengthSet s(double w, int r, {String type = 'normal'}) =>
    StrengthSet(weightKg: w, reps: r, type: type);

WorkoutLog wk(
  String id,
  DateTime at,
  List<ExerciseLog> ex, {
  String title = 'Push',
}) => WorkoutLog(
  id: id,
  title: title,
  startAt: at,
  localDate:
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}',
  source: 'manual',
  exercises: ex,
);

ExerciseLog bench(List<StrengthSet> sets, {String? muscle = 'chest'}) =>
    ExerciseLog(name: 'Bench Press', sets: sets, muscleGroup: muscle);

void main() {
  group('e1RM', () {
    test('Epley for 1–12 reps only', () {
      expect(epley1Rm(100, 1), 100);
      expect(epley1Rm(100, 5), closeTo(116.67, 0.01));
      expect(epley1Rm(100, 12), closeTo(140, 0.001));
      expect(epley1Rm(100, 13), isNull);
      expect(epley1Rm(100, 0), isNull);
      expect(epley1Rm(0, 5), isNull);
      expect(epley1Rm(null, 5), isNull);
    });

    test('warm-ups excluded from e1RM, best set and volume', () {
      final e = bench([s(140, 3, type: 'warmup'), s(100, 5), s(90, 8)]);
      expect(setE1Rm(e.sets.first), isNull);
      final best = bestSet(e)!;
      expect(best.set.weightKg, 100);
      expect(exerciseVolume(e), 100 * 5 + 90 * 8);
    });

    test('best set falls back to heaviest when no set qualifies', () {
      final e = bench([s(40, 20), s(50, 15)]);
      expect(bestSet(e)!.set.weightKg, 50);
      expect(bestSet(e)!.e1Rm, isNull);
    });
  });

  test('session volume and working sets exclude warm-ups', () {
    final w = wk('1', DateTime(2026, 10, 20), [
      bench([s(60, 10, type: 'warmup'), s(100, 5), s(100, 5)]),
    ]);
    expect(sessionVolume(w), 1000);
    expect(workingSetCount(w), 2);
  });

  group('PRs', () {
    test('first appearance is a baseline, later improvements are PRs', () {
      final w1 = wk('1', DateTime(2026, 10, 1), [
        bench([s(100, 5), s(100, 5)]),
      ]);
      final w2 = wk('2', DateTime(2026, 10, 8), [
        bench([s(105, 3), s(100, 6), s(100, 5), s(200, 1, type: 'warmup')]),
      ]);
      final w3 = wk('3', DateTime(2026, 10, 15), [
        bench([s(90, 5)]),
      ]);
      final prs = detectPrs([w3, w2, w1]);
      expect(prs.where((p) => p.workoutId == '1'), isEmpty);
      expect(prs.where((p) => p.workoutId == '3'), isEmpty);
      final types = prs.map((p) => p.type).toSet();
      expect(
        types,
        containsAll([
          PrType.weight,
          PrType.repsAtWeight,
          PrType.e1Rm,
          PrType.volume,
        ]),
      );
      final weight = prs.firstWhere((p) => p.type == PrType.weight);
      expect(weight.value, 105); // warm-up 200 kg ignored
      expect(weight.previous, 100);
      final reps = prs.firstWhere((p) => p.type == PrType.repsAtWeight);
      expect(reps.weightKg, 100);
      expect(reps.value, 6);
      expect(reps.previous, 5);
    });
  });

  test('weekly totals use Monday weeks and include empty weeks', () {
    final weeks = weeklyStrength(
      [
        wk('a', DateTime(2026, 10, 19, 8), [
          bench([s(100, 5)]),
        ]), // Mon
        wk('b', DateTime(2026, 10, 25, 8), [
          bench([s(100, 5)]),
        ]), // Sun
        wk('c', DateTime(2026, 10, 12, 8), [
          bench([s(50, 10)]),
        ]),
      ],
      todayKey: '2026-10-25',
      weeks: 3,
    );
    expect(weeks.map((w) => w.weekStart), [
      '2026-10-05',
      '2026-10-12',
      '2026-10-19',
    ]);
    expect(weeks.map((w) => w.sessions), [0, 1, 2]);
    expect(weeks.last.volumeKg, 1000);
  });

  test('muscle sets count mapped exercises only and report unmapped', () {
    final m = muscleGroupSets([
      wk('a', DateTime(2026, 10, 20), [
        bench([s(60, 10, type: 'warmup'), s(100, 5), s(100, 5)]),
        ExerciseLog(name: 'Mystery', sets: [s(10, 10), s(10, 10)]),
      ]),
    ]);
    expect(m.setsByGroup, {'chest': 2});
    expect(m.unmappedSets, 2);
    expect(m.unmappedExercises, {'Mystery'});
    expect(m.sufficientForBalance, isFalse);
  });

  group('progression', () {
    test('needs at least 3 sessions', () {
      expect(progression([100, 110]).trend, ProgressionTrend.notEnoughData);
    });
    test('improving / stable / declining thresholds (±0.5%/session)', () {
      expect(
        progression([100, 102, 104, 106]).trend,
        ProgressionTrend.improving,
      );
      expect(
        progression([100, 100.2, 99.9, 100.1]).trend,
        ProgressionTrend.stable,
      );
      expect(
        progression([110, 107, 104, 101]).trend,
        ProgressionTrend.declining,
      );
      // Just under the threshold → stable.
      expect(progression([100, 100.4, 100.8]).trend, ProgressionTrend.stable);
    });
    test('uses only the last N sessions', () {
      final r = progression([50, 60, 70, 100, 100, 100], lastN: 3);
      expect(r.trend, ProgressionTrend.stable);
      expect(r.sessions, 3);
    });
  });

  test('compares with previous session of the same title', () {
    final prev = wk('1', DateTime(2026, 10, 1), [
      bench([s(100, 5)]),
    ]);
    final other = wk('2', DateTime(2026, 10, 3), [
      bench([s(10, 5)]),
    ], title: 'Pull');
    final cur = wk('3', DateTime(2026, 10, 8), [
      bench([s(105, 5)]),
      ExerciseLog(name: 'Dips', sets: [s(0, 10)]),
    ], title: 'push');
    final c = compareWithPrevious(cur, [prev, other, cur])!;
    expect(c.previous.id, '1');
    expect(c.volumeDelta, 25);
    expect(c.exercises.first.e1RmDelta, closeTo(5 * (1 + 5 / 30), 1e-9));
    expect(c.exercises[1].e1RmDelta, isNull);
    expect(compareWithPrevious(prev, [prev, cur]), isNull);
  });
}
