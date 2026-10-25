import 'package:athlete_os/features/train/domain/hevy_csv_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const header =
      'title,start_time,end_time,description,exercise_title,superset_id,'
      'exercise_notes,set_index,set_type,weight_kg,reps,distance_km,'
      'duration_seconds,rpe';

  test('groups rows into workouts and exercises in file order', () {
    const csv =
        '$header\r\n'
        'Push A,"15 Oct 2026, 18:30","15 Oct 2026, 19:35","Good, strong",'
        'Bench Press (Barbell),,"Pause reps, ""tight""",0,warmup,60,10,,,\r\n'
        'Push A,"15 Oct 2026, 18:30","15 Oct 2026, 19:35","Good, strong",'
        'Bench Press (Barbell),,,1,normal,100,5,,,8.5\r\n'
        'Push A,"15 Oct 2026, 18:30","15 Oct 2026, 19:35","Good, strong",'
        'Plank,,,0,normal,,,,60,\r\n'
        'Pull,"16 Oct 2026, 07:00",,,Row,1,,0,dropset,50,12,,,\r\n';
    final r = parseHevyCsv(csv);
    expect(r.warnings, isEmpty);
    expect(r.workouts, hasLength(2));
    final push = r.workouts.first.draft;
    expect(push.title, 'Push A');
    expect(push.startAt, DateTime(2026, 10, 15, 18, 30));
    expect(push.endAt, DateTime(2026, 10, 15, 19, 35));
    expect(push.notes, 'Good, strong');
    expect(push.exercises.map((e) => e.name), [
      'Bench Press (Barbell)',
      'Plank',
    ]);
    final bench = push.exercises.first;
    expect(bench.notes, 'Pause reps, "tight"');
    expect(bench.sets.first.type, 'warmup');
    expect(bench.sets[1].weightKg, 100);
    expect(bench.sets[1].reps, 5);
    expect(bench.sets[1].rpe, 8.5);
    expect(push.exercises[1].sets.single.durationS, 60);
    final pull = r.workouts[1];
    expect(pull.externalKey, 'Pull|16 Oct 2026, 07:00');
    expect(pull.draft.exercises.single.supersetId, 1);
    expect(pull.draft.exercises.single.sets.single.type, 'dropset');
  });

  test('tolerates column order, ISO times and lbs/miles columns', () {
    const csv =
        'exercise_title,reps,weight_lbs,start_time,title,set_index,'
        'distance_miles\n'
        'Squat,5,225,2026-10-20T07:00:00Z,Legs,0,\n'
        'Run,,,2026-10-20T07:00:00Z,Legs,0,1\n';
    final r = parseHevyCsv(csv);
    final w = r.workouts.single.draft;
    expect(w.startAt, DateTime.utc(2026, 10, 20, 7));
    expect(w.exercises.first.sets.single.weightKg, closeTo(102.06, 0.01));
    expect(w.exercises[1].sets.single.distanceM, closeTo(1609.3, 0.1));
  });

  test('reports missing columns and bad rows', () {
    expect(parseHevyCsv('foo,bar\n1,2').workouts, isEmpty);
    expect(parseHevyCsv('foo,bar\n1,2').warnings.single, contains('title'));
    final r = parseHevyCsv(
      '$header\nX,not a date,,,Bench,,,0,normal,1,1,,,\n'
      ',"15 Oct 2026, 18:30",,,Bench,,,0,normal,1,1,,,\n',
    );
    expect(r.workouts, isEmpty);
    expect(r.warnings, hasLength(2));
  });

  test('parses Hevy date formats', () {
    expect(parseHevyCsvTime('8 Feb 2026, 07:16'), DateTime(2026, 2, 8, 7, 16));
    expect(
      parseHevyCsvTime('Oct 15, 2026, 6:30 PM'),
      DateTime(2026, 10, 15, 18, 30),
    );
    expect(parseHevyCsvTime('garbage'), isNull);
  });
}
