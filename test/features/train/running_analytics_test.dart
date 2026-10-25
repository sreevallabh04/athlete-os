import 'package:athlete_os/features/train/domain/run_review.dart';
import 'package:athlete_os/features/train/domain/running_analytics.dart';
import 'package:athlete_os/features/train/domain/running_models.dart';
import 'package:flutter_test/flutter_test.dart';

RunSplit km(int secs, {double d = 1000, double? hr}) =>
    RunSplit(distanceM: d, movingTimeS: secs, avgHr: hr);

RunActivity run(
  String id,
  DateTime at, {
  double? dist,
  int? time,
  List<RunSplit> splits = const [],
  String source = 'strava',
  String sport = 'run',
}) => RunActivity(
  id: id,
  source: source,
  sportType: sport,
  startAt: at,
  localDate:
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}',
  distanceM: dist,
  movingTimeS: time,
  splits: splits,
);

void main() {
  test('pace is seconds per km from moving time', () {
    expect(run('a', DateTime(2026), dist: 5000, time: 1500).paceSPerKm, 300);
    expect(run('a', DateTime(2026), dist: 50, time: 10).paceSPerKm, isNull);
  });

  test('split pace CV uses full-km splits only', () {
    final even = [km(300), km(300), km(300), km(150, d: 480)];
    expect(splitPaceCv(even), 0);
    final uneven = [km(280), km(300), km(320)];
    expect(splitPaceCv(uneven), closeTo(16.33 / 300, 0.001));
    expect(splitPaceCv([km(300), km(300)]), isNull);
  });

  test('negative / positive / even split detection', () {
    expect(
      splitComparison([km(320), km(310), km(300), km(290)])!.pattern,
      SplitPattern.negative,
    );
    expect(
      splitComparison([km(290), km(300), km(310), km(330)])!.pattern,
      SplitPattern.positive,
    );
    expect(
      splitComparison([km(300), km(301), km(299), km(302)])!.pattern,
      SplitPattern.even,
    );
  });

  test('HR drift compares first and second half of split HR', () {
    final d = hrDrift([
      km(300, hr: 150),
      km(300, hr: 150),
      km(300, hr: 160),
      km(300, hr: 160),
    ])!;
    expect(d.driftFraction, closeTo(10 / 150, 1e-9));
    expect(hrDrift([km(300, hr: 150)]), isNull);
  });

  group('best 5K', () {
    test('fastest 5 consecutive full-km splits', () {
      final r = run(
        'a',
        DateTime(2026, 10, 1),
        dist: 7200,
        time: 2200,
        splits: [
          km(330),
          km(300),
          km(310),
          km(290),
          km(300),
          km(320),
          km(305),
          km(60, d: 200),
        ],
      );
      final b = best5kForRun(r)!;
      expect(b.method, Best5kMethod.splits);
      // windows: 330+300+310+290+300=1530, 300+310+290+300+320=1520,
      //          310+290+300+320+305=1525
      expect(b.timeS, 1520);
    });

    test('a short split breaks the sequence', () {
      final r = run(
        'a',
        DateTime(2026),
        dist: 5600,
        splits: [km(300), km(300), km(100, d: 600), km(300), km(300)],
      );
      expect(best5kForRun(r), isNull);
    });

    test('whole-run fallback only for 4.9–5.3 km, labelled', () {
      final a = best5kForRun(run('a', DateTime(2026), dist: 5100, time: 1700))!;
      expect(a.method, Best5kMethod.wholeRun);
      expect(a.timeS, 1700);
      expect(a.label, contains('5.10 km'));
      final b = best5kForRun(run('b', DateTime(2026), dist: 4900, time: 1470))!;
      expect(b.timeS, 1500); // scaled up to 5 km
      expect(
        best5kForRun(run('c', DateTime(2026), dist: 5400, time: 1500)),
        isNull,
      );
      expect(
        best5kForRun(run('d', DateTime(2026), dist: 4800, time: 1400)),
        isNull,
      );
      expect(
        best5kForRun(
          run('e', DateTime(2026), dist: 5000, time: 1, sport: 'ride'),
        ),
        isNull,
      );
    });
  });

  test('goal progress vs runGoalTimeS', () {
    final g = goalProgress(
      Best5k(
        timeS: 1950,
        method: Best5kMethod.splits,
        activityId: 'a',
        date: DateTime(2026, 10, 1),
        label: 'x',
      ),
      goalTimeS: 1800,
    );
    expect(g.achieved, isFalse);
    expect(g.gapS, 150);
    expect(g.fraction, closeTo(1800 / 1950, 1e-9));
    expect(g.goalPaceSPerKm, 360);
    final none = goalProgress(null, goalTimeS: 1800);
    expect(none.hasData, isFalse);
    expect(none.fraction, 0);
  });

  test('weekly running totals and consistency', () {
    final acts = [
      run('a', DateTime(2026, 10, 20, 7), dist: 5000, time: 1600),
      run('b', DateTime(2026, 10, 22, 7), dist: 3000, time: 1000),
      run('c', DateTime(2026, 10, 14, 7), dist: 4000, time: 1300),
      run(
        'w',
        DateTime(2026, 10, 21, 7),
        dist: 9000,
        time: 5000,
        sport: 'walk',
      ),
    ];
    final w = weeklyRunning(acts, todayKey: '2026-10-25', weeks: 3);
    expect(w.last.distanceM, 8000);
    expect(w.last.runs, 2);
    expect(w[1].runs, 1);
    final c = runConsistency(acts, todayKey: '2026-10-25', weeks: 3);
    expect(c.weeksWithRuns, 2);
    expect(c.currentStreakWeeks, 2);
  });

  group('dedupe Strava vs Health Connect', () {
    test('same run within ±3 min and ±5% distance is shown once', () {
      final s = run('s', DateTime(2026, 10, 20, 7, 0), dist: 5000, time: 1600);
      final hc = run(
        'h',
        DateTime(2026, 10, 20, 7, 2),
        dist: 5150,
        time: 1620,
        source: 'health_connect',
      );
      final other = run(
        'o',
        DateTime(2026, 10, 20, 7, 10),
        dist: 5000,
        source: 'health_connect',
      );
      final out = dedupeActivities([hc, s, other]);
      expect(out.map((a) => a.id), ['o', 's']);
      final kept = out.firstWhere((a) => a.id == 's');
      expect(kept.alsoInHealthConnect, isTrue);
      expect(kept.duplicateIds, ['h']);
    });

    test('distance difference > 5% is not a duplicate', () {
      final s = run('s', DateTime(2026, 10, 20, 7), dist: 5000);
      final hc = run(
        'h',
        DateTime(2026, 10, 20, 7),
        dist: 5400,
        source: 'health_connect',
      );
      expect(dedupeActivities([s, hc]), hasLength(2));
    });
  });

  group('rule-based review', () {
    test('never suggests more than +10% weekly volume', () {
      // Last week 20 km; this week already 20 km → at most 2 km more.
      final lastWeek = [
        for (var i = 0; i < 4; i++)
          run('l$i', DateTime(2026, 10, 13 + i, 7), dist: 5000, time: 1600),
      ];
      final thisWeek = [
        for (var i = 0; i < 3; i++)
          run('t$i', DateTime(2026, 10, 19 + i, 7), dist: 5000, time: 1600),
      ];
      final current = run(
        'c',
        DateTime(2026, 10, 23, 7),
        dist: 5000,
        time: 1600,
      );
      final review = reviewRun(current, [
        ...lastWeek,
        ...thisWeek,
      ], todayKey: '2026-10-23');
      expect(20 + review.next.distanceKm, lessThanOrEqualTo(20 * 1.1 + 1e-9));

      // Already above +10% → rest / cross-train, 0 km.
      final extra = run(
        'x',
        DateTime(2026, 10, 22, 18),
        dist: 5000,
        time: 1600,
      );
      final r2 = reviewRun(current, [
        ...lastWeek,
        ...thisWeek,
        extra,
      ], todayKey: '2026-10-23');
      expect(r2.next.type, NextWorkoutType.rest);
      expect(r2.next.distanceKm, 0);
    });

    test('suggestion fits the remaining weekly budget', () {
      final history = [
        for (var i = 0; i < 4; i++)
          run('l$i', DateTime(2026, 10, 13 + i, 7), dist: 8000, time: 2600),
      ];
      final current = run(
        'c',
        DateTime(2026, 10, 19, 7),
        dist: 8000,
        time: 2600,
      );
      for (final hard in [true, false]) {
        final next = suggestNextWorkout(
          run: current,
          history: history,
          todayKey: '2026-10-19',
          hardEffort: hard,
          negativeTrend: false,
        );
        // last week 32 km → cap 35.2; this week 8 → ≤ 27.2 km more.
        expect(8 + next.distanceKm, lessThanOrEqualTo(32 * 1.1));
        expect(next.distanceKm, greaterThan(0));
        if (hard) expect(next.type, NextWorkoutType.easy);
      }
    });

    test('without a baseline week the suggestion is capped at 5 km', () {
      final current = run(
        'c',
        DateTime(2026, 10, 19, 7),
        dist: 10000,
        time: 3600,
      );
      final next = suggestNextWorkout(
        run: current,
        history: const [],
        todayKey: '2026-10-19',
        hardEffort: false,
        negativeTrend: false,
      );
      expect(next.distanceKm, lessThanOrEqualTo(5));
    });

    test('review has label-worthy fields and an uncertainty note', () {
      final current = run(
        'c',
        DateTime(2026, 10, 19, 7),
        dist: 4000,
        time: 1200,
        splits: [
          km(310, hr: 150),
          km(300, hr: 152),
          km(295, hr: 160),
          km(295, hr: 165),
        ],
      );
      final r = reviewRun(current, const [], todayKey: '2026-10-19');
      expect(r.summary, contains('4.00 km'));
      expect(r.splitComparison!.pattern, SplitPattern.negative);
      expect(r.hrDrift, isNotNull);
      expect(r.uncertainty, contains('weather'));
      expect(r.takeaway, isNotEmpty);
      expect(kReviewLabel, 'Automated analysis (rule-based, no AI)');
    });
  });
}
