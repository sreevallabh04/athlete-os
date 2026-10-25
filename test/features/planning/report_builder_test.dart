import 'dart:convert';

import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/planning/data/metrics_queries.dart';
import 'package:athlete_os/features/planning/domain/habit_schedule.dart';
import 'package:athlete_os/features/planning/domain/metrics.dart';
import 'package:athlete_os/features/planning/domain/report_builder.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/test_app.dart';

const targets = ReportTargets(
  calorieTarget: 2000,
  proteinTargetG: 150,
  stepGoal: 10000,
  waterGoalMl: 3000,
);

ReportInput week({
  Map<String, DayNutrition> nutrition = const {},
  List<DailyMetric> steps = const [],
  List<CardioRecord> cardio = const [],
  List<WorkoutRecord> workouts = const [],
  List<StrengthSet> sets = const [],
  Map<String, int> water = const {},
  List<WeightPoint> weights = const [],
  String start = '2026-10-19',
  String end = '2026-10-25',
  String asOf = '2026-10-25',
}) => ReportInput(
  kind: 'weekly',
  periodStart: start,
  periodEnd: end,
  asOfDate: asOf,
  targets: targets,
  nutrition: nutrition,
  steps: steps,
  cardio: cardio,
  workouts: workouts,
  sets: sets,
  water: water,
  weights: weights,
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('pure aggregates', () {
    test('nutrition averages use logged days only; adherence counts', () {
      final n = ReportBuilder.computeNumbers(
        week(
          nutrition: const {
            '2026-10-19': DayNutrition(
              date: '2026-10-19',
              kcal: 2000,
              proteinG: 160,
              entries: 3,
            ),
            '2026-10-20': DayNutrition(
              date: '2026-10-20',
              kcal: 2300,
              proteinG: 140,
              entries: 4,
            ),
            '2026-10-22': DayNutrition(
              date: '2026-10-22',
              kcal: 1700,
              proteinG: 150,
              entries: 2,
            ),
            '2026-10-30': DayNutrition(
              date: '2026-10-30',
              kcal: 9999,
              proteinG: 999,
              entries: 1,
            ),
          },
        ),
      );
      expect(n['days'], 7);
      expect(n['nutrition.loggedDays'], 3);
      expect(n['nutrition.avgKcal'], closeTo(2000, 1e-9));
      expect(n['nutrition.avgProteinG'], closeTo(150, 1e-9));
      expect(n['nutrition.proteinDays'], 2); // 160 and 150 (>= target)
      expect(n['nutrition.calorieDays'], 1); // only 2000 is within ±10%
      expect(n['nutrition.proteinAdherencePct'], closeTo(66.67, 0.01));
    });

    test('no food logged => averages are null, not zero', () {
      final n = ReportBuilder.computeNumbers(week());
      expect(n['nutrition.loggedDays'], 0);
      expect(n['nutrition.avgKcal'], isNull);
      expect(n['nutrition.proteinAdherencePct'], isNull);
      final r = ReportBuilder.build(week());
      final s = r.sections.firstWhere((s) => s.key == 'nutrition');
      expect(s.available, isFalse);
    });

    test('strength volume excludes warm-ups and incomplete sets', () {
      final sets = [
        const StrengthSet(
          workoutId: 'w1',
          date: '2026-10-20',
          exercise: 'Bench',
          setType: 'warmup',
          weightKg: 40,
          reps: 10,
        ),
        const StrengthSet(
          workoutId: 'w1',
          date: '2026-10-20',
          exercise: 'Bench',
          weightKg: 60,
          reps: 8,
        ),
        const StrengthSet(
          workoutId: 'w1',
          date: '2026-10-20',
          exercise: 'Bench',
          setType: 'failure',
          weightKg: 60,
          reps: 8,
        ),
        const StrengthSet(
          workoutId: 'w1',
          date: '2026-10-20',
          exercise: 'Plank',
          weightKg: null,
          reps: null,
        ),
        const StrengthSet(
          workoutId: 'w2',
          date: '2026-10-23',
          exercise: 'Bench',
          weightKg: 65,
          reps: 5,
        ),
      ];
      expect(totalVolume(sets), 60 * 8 * 2 + 65 * 5);
      final top = topExerciseProgress(sets)!;
      expect(top.exercise, 'Bench');
      expect(top.firstTopKg, 60);
      expect(top.lastTopKg, 65);
      final n = ReportBuilder.computeNumbers(
        week(
          sets: sets,
          workouts: [
            WorkoutRecord(
              id: 'w1',
              title: 'Push',
              date: '2026-10-20',
              source: 'hevy',
              startAt: DateTime.utc(2026, 10, 20),
            ),
            WorkoutRecord(
              id: 'w2',
              title: 'Push',
              date: '2026-10-23',
              source: 'manual',
              startAt: DateTime.utc(2026, 10, 23),
            ),
          ],
        ),
      );
      expect(n['strength.workouts'], 2);
      expect(n['strength.volumeKg'], 1285);
      expect(n['strength.perWeek'], closeTo(2, 1e-9));
    });

    test('runs exclude walks; pace only from runs with distance and time', () {
      final cardio = [
        CardioRecord(
          date: '2026-10-20',
          sportType: 'run',
          source: 'strava',
          startAt: DateTime.utc(2026, 10, 20),
          distanceM: 5000,
          movingTimeS: 1500,
        ),
        CardioRecord(
          date: '2026-10-21',
          sportType: 'walk',
          source: 'health_connect',
          startAt: DateTime.utc(2026, 10, 21),
          distanceM: 3000,
          movingTimeS: 1800,
        ),
        CardioRecord(
          date: '2026-10-22',
          sportType: 'run',
          source: 'manual',
          startAt: DateTime.utc(2026, 10, 22),
          distanceM: 3000,
        ),
      ];
      final s = summarizeRuns(cardio);
      expect(s.count, 2);
      expect(s.distanceM, 8000);
      expect(s.avgPaceSecPerKm, closeTo(300, 1e-9));
      expect(s.excludedNonRuns, 1);
      expect(s.sources, {'strava', 'manual'});
      final r = ReportBuilder.build(week(cardio: cardio));
      final running = r.sections.firstWhere((x) => x.key == 'running');
      expect(
        running.metrics.firstWhere((m) => m.label == 'Distance').value,
        '8.00 km',
      );
      expect(running.metrics.first.source, 'Manual + Strava');
      expect(running.note, contains('excluded'));
    });

    test('steps prefer Health Connect over manual for the same day', () {
      final n = ReportBuilder.computeNumbers(
        week(
          steps: const [
            DailyMetric(
              date: '2026-10-19',
              value: 12000,
              origin: 'health_connect',
            ),
            DailyMetric(date: '2026-10-19', value: 500, origin: 'manual'),
            DailyMetric(date: '2026-10-20', value: 8000, origin: 'manual'),
          ],
        ),
      );
      expect(n['steps.days'], 2);
      expect(n['steps.avg'], 10000);
      expect(n['steps.goalDays'], 1);
    });

    test('hydration adherence and in-progress period day count', () {
      final n = ReportBuilder.computeNumbers(
        week(
          asOf: '2026-10-22', // Thursday: only Mon..Thu counted
          water: const {
            '2026-10-19': 3200,
            '2026-10-20': 1000,
            '2026-10-24': 5000,
          },
        ),
      );
      expect(n['days'], 4);
      expect(n['hydration.loggedDays'], 2);
      expect(n['hydration.goalDays'], 1);
      expect(n['hydration.adherencePct'], 25);
    });

    test(
      'improvement is the largest relative increase; focus is rule-based',
      () {
        final prev = week(
          start: '2026-10-12',
          end: '2026-10-18',
          steps: const [
            DailyMetric(date: '2026-10-12', value: 5000, origin: 'manual'),
          ],
          cardio: [
            CardioRecord(
              date: '2026-10-13',
              sportType: 'run',
              source: 'manual',
              startAt: DateTime.utc(2026, 10, 13),
              distanceM: 5000,
            ),
          ],
        );
        final cur = week(
          steps: const [
            DailyMetric(date: '2026-10-19', value: 6000, origin: 'manual'),
          ],
          cardio: [
            CardioRecord(
              date: '2026-10-20',
              sportType: 'run',
              source: 'manual',
              startAt: DateTime.utc(2026, 10, 20),
              distanceM: 10000,
            ),
          ],
        );
        final r = ReportBuilder.build(cur, previous: prev);
        expect(r.improvement.title, 'Running distance');
        expect(r.improvement.detail, contains('+100%'));
        expect(r.improvement.rule, startsWith('Rule-based'));
        expect(r.focus.title, 'Log meals consistently');
        expect(r.focus.rule, startsWith('Rule 1'));
        expect(
          ReportBuilder.build(cur).improvement.title,
          'Not enough history yet',
        );
      },
    );

    test('report JSON round-trips', () {
      final r = ReportBuilder.build(
        week(
          nutrition: const {
            '2026-10-19': DayNutrition(
              date: '2026-10-19',
              kcal: 2000,
              proteinG: 160,
              entries: 3,
            ),
          },
          weights: [
            WeightPoint(
              date: '2026-10-19',
              at: DateTime.utc(2026, 10, 19, 7),
              kg: 80.2,
              origin: 'manual',
            ),
            WeightPoint(
              date: '2026-10-21',
              at: DateTime.utc(2026, 10, 21, 7),
              kg: 79.8,
              origin: 'health_connect',
            ),
          ],
        ),
      );
      final back = PeriodReport.fromJson(
        (jsonDecode(jsonEncode(r.toJson())) as Map).cast<String, Object?>(),
      );
      expect(back.periodStart, r.periodStart);
      expect(back.sections.length, r.sections.length);
      expect(back.series.map((s) => s.key), r.series.map((s) => s.key));
      expect(back.numbers['nutrition.loggedDays'], 1);
      expect(back.focus.title, r.focus.title);
      final weight = back.sections.firstWhere((s) => s.key == 'weight');
      expect(weight.note, contains('not fat or muscle'));
    });

    test('7-day trailing moving average skips missing days', () {
      final pts = [
        WeightPoint(
          date: '2026-10-01',
          at: DateTime.utc(2026, 10, 1),
          kg: 80,
          origin: 'manual',
        ),
        WeightPoint(
          date: '2026-10-01',
          at: DateTime.utc(2026, 10, 1, 20),
          kg: 81,
          origin: 'manual',
        ),
        WeightPoint(
          date: '2026-10-03',
          at: DateTime.utc(2026, 10, 3),
          kg: 79,
          origin: 'manual',
        ),
        WeightPoint(
          date: '2026-10-09',
          at: DateTime.utc(2026, 10, 9),
          kg: 78,
          origin: 'manual',
        ),
      ];
      final ma = trailingMovingAverage(pts);
      expect(ma.map((p) => p.date), ['2026-10-01', '2026-10-03', '2026-10-09']);
      expect(ma[0].value, 80.5);
      expect(ma[1].value, closeTo((80.5 + 79) / 2, 1e-9));
      // Oct 9 window is Oct 3..9.
      expect(ma[2].value, closeTo((79 + 78) / 2, 1e-9));
    });

    test('nutrition adherence ±10% and protein', () {
      final a = nutritionAdherence(
        const {
          'a': DayNutrition(date: 'a', kcal: 2200, proteinG: 150, entries: 1),
          'b': DayNutrition(date: 'b', kcal: 2201, proteinG: 149, entries: 1),
          'c': DayNutrition(date: 'c', kcal: 1800, proteinG: 200, entries: 1),
        },
        const ['a', 'b', 'c', 'd'],
        calorieTarget: 2000,
        proteinTargetG: 150,
      );
      expect(a.loggedDays, 3);
      expect(a.calorieDays, 2);
      expect(a.proteinDays, 2);
      expect(a.bothDays, 2);
      expect(a.totalDays, 4);
    });
  });

  group('seeded database', () {
    test('MetricsQueries + ReportBuilder over real tables', () async {
      final db = newTestDb();
      addTearDown(db.close);
      DateTime at(String d, [int h = 12]) =>
          DateTime.parse('${d}T${h.toString().padLeft(2, '0')}:00:00Z');

      Future<void> food(
        String d,
        double kcal,
        double p, {
        bool deleted = false,
      }) => db
          .into(db.foodLogEntries)
          .insert(
            FoodLogEntriesCompanion.insert(
              id: 'f$d$kcal',
              name: 'Meal',
              mealType: 'lunch',
              calories: kcal,
              proteinG: Value(p),
              source: 'custom',
              verification: 'user_entered',
              loggedAt: at(d),
              localDate: d,
              tzName: 'UTC',
              deletedAt: Value(deleted ? at(d) : null),
            ),
          );
      await food('2026-10-19', 1200, 90);
      await food('2026-10-19', 800, 70); // day total 2000 / 160
      await food('2026-10-21', 2500, 120);
      await food('2026-10-22', 5000, 500, deleted: true); // soft-deleted

      await db
          .into(db.workouts)
          .insert(
            WorkoutsCompanion.insert(
              id: 'w1',
              source: 'hevy',
              title: 'Upper',
              startAt: at('2026-10-20', 7),
              localDate: '2026-10-20',
            ),
          );
      await db
          .into(db.workoutExercises)
          .insert(
            WorkoutExercisesCompanion.insert(
              id: 'e1',
              workoutId: 'w1',
              position: 0,
              name: 'Bench Press',
            ),
          );
      await db
          .into(db.workoutSets)
          .insert(
            WorkoutSetsCompanion.insert(
              id: 's1',
              exerciseId: 'e1',
              position: 0,
              setType: const Value('warmup'),
              weightKg: const Value(40),
              reps: const Value(10),
            ),
          );
      await db
          .into(db.workoutSets)
          .insert(
            WorkoutSetsCompanion.insert(
              id: 's2',
              exerciseId: 'e1',
              position: 1,
              weightKg: const Value(70),
              reps: const Value(8),
            ),
          );

      await db
          .into(db.cardioActivities)
          .insert(
            CardioActivitiesCompanion.insert(
              id: 'r1',
              source: 'strava',
              sportType: 'run',
              startAt: at('2026-10-21', 6),
              localDate: '2026-10-21',
              distanceM: const Value(5000),
              movingTimeS: const Value(1650),
            ),
          );
      await db
          .into(db.cardioActivities)
          .insert(
            CardioActivitiesCompanion.insert(
              id: 'r2',
              source: 'health_connect',
              sportType: 'walk',
              startAt: at('2026-10-21', 18),
              localDate: '2026-10-21',
              distanceM: const Value(4000),
              movingTimeS: const Value(2700),
            ),
          );
      await db
          .into(db.dailyHealthSummaries)
          .insert(
            DailyHealthSummariesCompanion.insert(
              localDate: '2026-10-19',
              type: 'steps',
              value: 11000,
              unit: 'count',
              origin: 'health_connect',
            ),
          );
      await db
          .into(db.waterLogs)
          .insert(
            WaterLogsCompanion.insert(
              id: 'wl',
              amountMl: 3000,
              loggedAt: at('2026-10-19'),
              localDate: '2026-10-19',
            ),
          );
      await db
          .into(db.habits)
          .insert(HabitsCompanion.insert(id: 'h1', name: 'Stretch'));
      await db
          .into(db.habitCompletions)
          .insert(
            HabitCompletionsCompanion.insert(
              id: 'hc1',
              habitId: 'h1',
              localDate: '2026-10-19',
            ),
          );

      final input = await MetricsQueries(db).reportInput(
        kind: 'weekly',
        start: '2026-10-19',
        end: '2026-10-25',
        now: DateTime.utc(2026, 10, 25, 20),
      );
      final r = ReportBuilder.build(input);
      final n = r.numbers;
      expect(n['nutrition.loggedDays'], 2);
      expect(n['nutrition.avgKcal'], 2250);
      expect(n['nutrition.proteinDays'], 1);
      expect(n['strength.workouts'], 1);
      expect(n['strength.volumeKg'], 560);
      expect(n['run.count'], 1);
      expect(n['run.distanceKm'], 5);
      expect(n['run.avgPaceSecPerKm'], 330);
      expect(n['steps.avg'], 11000);
      expect(n['hydration.goalDays'], 1);
      expect(n['habits.completed'], 1);
      expect(n['habits.expected'], 7);
      expect(input.habits.single, isA<HabitSpec>());
      expect(
        r.sections.firstWhere((s) => s.key == 'running').metrics.first.source,
        'Strava',
      );
    });
  });
}
