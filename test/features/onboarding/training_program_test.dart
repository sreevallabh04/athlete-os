import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-10-19 is a Monday.
  final program = generateMensPhysiqueProgram(startMonday: '2026-10-19');

  String dayOf(int week, int weekday) {
    final d = DateTime(2026, 10, 19 + (week - 1) * 7 + weekday - 1);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  test('7 days: 5 lifting (incl. Sunday pump) + 2 runs, no rest days', () {
    expect(program.days, hasLength(7));
    expect(program.liftDays, 5);
    expect(program.runDays, 2);
    expect([for (final d in program.days) d.weekday], [1, 2, 3, 4, 5, 6, 7]);
    expect(program.days[2].kind, SessionKind.run); // Wednesday
    expect(program.days[5].kind, SessionKind.run); // Saturday
    expect(program.days[6].kind, SessionKind.recovery); // Sunday pump
    for (final d in program.days.where((d) => d.isLift)) {
      expect(d.minutes, inInclusiveRange(45, 75));
      for (final e in d.exercises) {
        expect(e.info, isNotNull, reason: e.name);
        expect(e.repMin, lessThanOrEqualTo(e.repMax));
        expect(e.rir, inInclusiveRange(0, 3));
      }
    }
  });

  test('JSON round-trip', () {
    final back = TrainingProgram.fromJson(program.toJson())!;
    expect(back.toJson(), program.toJson());
  });

  test('deload every 6th week cuts lifting volume by ~40 %', () {
    expect(program.isDeloadWeek(6), isTrue);
    expect(program.isDeloadWeek(12), isTrue);
    expect(program.isDeloadWeek(5), isFalse);
    final normal = program.sessionFor(dayOf(5, 1));
    final deload = program.sessionFor(dayOf(6, 1));
    expect(deload.title, contains('Deload'));
    final ratio = deload.totalSets / normal.totalSets;
    expect(ratio, closeTo(0.6, 0.08));
    expect(deload.exercises.first.rir, normal.exercises.first.rir + 1);
    final deloadRun = program.sessionFor(dayOf(6, 6)).run!;
    expect(deloadRun.type, 'easy');
    expect(program.weekNumber(dayOf(6, 7)), 6);
    expect(program.weekNumber(dayOf(7, 1)), 7);
  });

  test('run paces derive from the 5K goal (30:00 → 6:00/km)', () {
    final z = program.paces;
    expect(z.goalPaceS, 360);
    expect(z.easy, (420, 465)); // 7:00–7:45
    expect(formatPaceRange(z.easy.$1, z.easy.$2), '7:00–7:45/km');
    expect(z.interval.$2, lessThan(360));
    expect(z.tempo.$1, greaterThan(360));
    final wed = program.sessionFor(dayOf(1, 3)).run!;
    expect(wed.type, 'easy');
    expect((wed.paceMinS, wed.paceMaxS), (420, 465));
    final sat = program.sessionFor(dayOf(1, 6)).run!;
    expect(sat.type, isNot('easy'));
  });

  test('easy-run duration grows ≤ 10 % per week, capped at 40 min', () {
    var prev = 0;
    for (var w = 1; w <= 5; w++) {
      final m = program.sessionFor(dayOf(w, 3)).run!.minutes;
      if (prev > 0) expect(m / prev, lessThanOrEqualTo(1.10001));
      expect(m, inInclusiveRange(30, 40));
      prev = m;
    }
  });

  test('restriction on shoulder swaps to safe substitutes with warnings', () {
    final push = program.sessionFor(dayOf(1, 1));
    final r = applyRestrictions(push, const [
      TrainingRestriction(
        description: 'Left shoulder impingement',
        bodyPart: 'Shoulder',
      ),
    ]);
    final names = r.day.exercises.map((e) => e.name).toList();
    expect(names, isNot(contains('Incline Dumbbell Press')));
    expect(names, contains('Incline Machine Press'));
    expect(names, isNot(contains('Seated Dumbbell Shoulder Press')));
    expect(r.warnings, isNotEmpty);
    expect(r.warnings.first.original, 'Incline Dumbbell Press');
    expect(r.warnings.first.substitute, 'Incline Machine Press');
    // Unrelated restriction changes nothing.
    final none = applyRestrictions(push, const [
      TrainingRestriction(description: 'Sprained ankle'),
    ]);
    expect(none.warnings, isEmpty);
  });

  test('lower-back restriction on legs day replaces RDL', () {
    final legs = program.sessionFor(dayOf(1, 4));
    final r = applyRestrictions(legs, const [
      TrainingRestriction(description: 'Lumbar disc bulge'),
    ]);
    expect(
      r.day.exercises.map((e) => e.name),
      isNot(contains('Romanian Deadlift')),
    );
    expect(r.warnings.map((w) => w.original), contains('Romanian Deadlift'));
  });

  test('active restrictions respect start/end dates', () {
    final list = activeRestrictions(const [
      (description: 'Knee', bodyPart: 'knee', start: null, end: '2026-10-01'),
      (description: 'Elbow', bodyPart: 'elbow', start: '2026-10-01', end: null),
    ], '2026-10-25');
    expect(list.map((r) => r.description), ['Elbow']);
  });

  test('readiness: low energy or < 6 h sleep suggests a lighter day', () {
    expect(const Readiness(energy: 2).suggestLighter, isTrue);
    expect(const Readiness(sleepMinutes: 330).suggestLighter, isTrue);
    expect(const Readiness(energy: 4, sleepMinutes: 420).suggestLighter, false);
    expect(const Readiness().suggestLighter, isFalse);
    final s = planSession(
      program: program,
      date: dayOf(1, 2),
      readiness: const Readiness(energy: 1),
    );
    final lighter = s.lighter!;
    expect(lighter.totalSets, lessThan(s.day.totalSets));
    expect(lighter.exercises.first.rir, s.day.exercises.first.rir + 1);
    final run = planSession(
      program: program,
      date: dayOf(1, 6),
      readiness: const Readiness(sleepMinutes: 300),
    ).lighter!;
    expect(run.run!.type, 'easy');
  });
}
