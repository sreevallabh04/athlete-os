import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:athlete_os/features/train/domain/running_models.dart';
import 'package:athlete_os/features/train/domain/strength_models.dart';
import 'package:athlete_os/features/train/presentation/widgets/prs.dart';
import 'package:athlete_os/features/train/presentation/widgets/week_plan.dart';
import 'package:flutter_test/flutter_test.dart';

WorkoutLog workout(String id, String date, {double kg = 80, int reps = 5}) {
  final d = DateTime.parse('${date}T06:30:00');
  return WorkoutLog(
    id: id,
    title: 'Push',
    startAt: d,
    localDate: date,
    source: 'manual',
    exercises: [
      ExerciseLog(
        name: 'Bench Press',
        sets: [StrengthSet(weightKg: kg, reps: reps)],
      ),
    ],
  );
}

RunActivity run(String id, String date) => RunActivity(
  id: id,
  source: 'health_connect',
  sportType: 'run',
  startAt: DateTime.parse('${date}T06:30:00'),
  localDate: date,
  distanceM: 5000,
  movingTimeS: 1900,
);

void main() {
  // Week of Mon 19 Oct 2026; program started that Monday.
  final program = generateMensPhysiqueProgram(startMonday: '2026-10-19');

  test('first run: past days are untracked, never "missed"', () {
    final days = planWeek(
      program: program,
      today: '2026-10-23',
      workouts: const [],
      activities: const [],
    );
    expect(days.map((d) => d.state).toList(), [
      DayState.untracked,
      DayState.untracked,
      DayState.untracked,
      DayState.untracked,
      DayState.today,
      DayState.upcoming,
      DayState.upcoming,
    ]);
  });

  test('lift days need a workout, run days need a run', () {
    final days = planWeek(
      program: program,
      today: '2026-10-23',
      workouts: [
        workout('w0', '2026-10-12'), // tracking started last week
        workout('w1', '2026-10-19'),
        workout('w3', '2026-10-21'), // a lift on the run day ≠ the run
      ],
      activities: [run('r1', '2026-10-22')], // a run on legs day ≠ legs
    );
    expect(days[0].state, DayState.done); // Mon push
    expect(days[1].state, DayState.missed); // Tue pull
    expect(days[2].state, DayState.missed); // Wed easy run
    expect(days[3].state, DayState.missed); // Thu legs
    expect(days[4].state, DayState.today);
    expect(days[0].workout?.id, 'w1');
  });

  test('today turns done once logged', () {
    final days = planWeek(
      program: program,
      today: '2026-10-24',
      workouts: const [],
      activities: [run('r', '2026-10-24')],
    );
    expect(days[5].state, DayState.done);
    expect(days[5].run?.id, 'r');
  });

  test('shortSessionTitle keeps the week strip readable', () {
    expect(shortSessionTitle('Push'), 'Push');
    expect(shortSessionTitle('Upper · V-taper'), 'Upper');
    expect(shortSessionTitle('5K session'), '5K');
    expect(shortSessionTitle('Weak-point pump'), 'Pump');
  });

  test('recentPrs keeps one record per lift and session, newest first', () {
    final prs = recentPrs([
      workout('a', '2026-10-01', kg: 80, reps: 5),
      workout('b', '2026-10-08', kg: 85, reps: 5),
      workout('c', '2026-10-15', kg: 87.5, reps: 6),
    ]);
    expect(prs.map((p) => p.workoutId).toList(), ['c', 'b']);
    expect(prs.first.exerciseName, 'Bench Press');
  });
}
