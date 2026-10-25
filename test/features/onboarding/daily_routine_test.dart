import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/domain/daily_routine.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = CalibrationAnswers.interviewDefaults();
  final program = generateMensPhysiqueProgram(startMonday: '2026-10-19');

  List<RoutineBlock> dayFor(String date) => routineFor(
    a: a,
    date: date,
    proteinTargetG: 170,
    session: planSession(program: program, date: date),
  );

  void expectWellFormed(List<RoutineBlock> blocks) {
    for (var i = 1; i < blocks.length; i++) {
      expect(
        blocks[i].start,
        greaterThanOrEqualTo(blocks[i - 1].start),
        reason: 'sorted',
      );
    }
    for (final b in blocks) {
      expect(b.end, greaterThan(b.start), reason: b.title);
    }
    final outside = blocks.where((b) => !b.atOffice).toList();
    for (var i = 0; i < outside.length; i++) {
      for (var j = i + 1; j < outside.length; j++) {
        expect(
          outside[i].overlaps(outside[j]),
          isFalse,
          reason: '${outside[i].title} overlaps ${outside[j].title}',
        );
      }
    }
    final office = blocks.where((b) => b.kind == RoutineKind.office);
    for (final b in blocks.where((b) => b.atOffice)) {
      expect(office, isNotEmpty);
      expect(b.start, greaterThanOrEqualTo(office.first.start));
      expect(b.end, lessThanOrEqualTo(office.first.end));
    }
  }

  test('office day (Mon) timeline is ordered, non-overlapping', () {
    final blocks = dayFor('2026-10-26');
    expectWellFormed(blocks);
    expect(blocks.first.kind, RoutineKind.wake);
    expect(blocks.first.start, 6 * 60);
    expect(blocks.last.kind, RoutineKind.sleep);
    expect(blocks.last.start, 22 * 60 + 30);
    final training = blocks.firstWhere((b) => b.kind == RoutineKind.training);
    expect(training.start, 6 * 60 + 30);
    expect(training.end, lessThanOrEqualTo(7 * 60 + 45));
    expect(training.title, startsWith('Push'));
    final office = blocks.firstWhere((b) => b.kind == RoutineKind.office);
    expect((office.start, office.end), (630, 1110));
    expect(blocks.where((b) => b.kind == RoutineKind.focus), hasLength(2));
    expect(blocks.where((b) => b.kind == RoutineKind.walk), isNotEmpty);
    final windDown = blocks.firstWhere((b) => b.kind == RoutineKind.windDown);
    expect(windDown.end, 22 * 60 + 30);
    final review = blocks.firstWhere((b) => b.title == 'Evening review');
    expect(review.start, 21 * 60 + 45);
  });

  test('meals distribute protein (4 × ~40–45 g, eggetarian examples)', () {
    final meals = dayFor('2026-10-26')
        .where((b) => b.kind == RoutineKind.meal)
        .toList();
    expect(meals, hasLength(4));
    for (final m in meals) {
      expect(m.proteinG, inInclusiveRange(35, 45));
      expect(m.detail, contains('g protein ·'));
    }
    final total = meals.fold<int>(0, (s, m) => s + m.proteinG!);
    expect(total, closeTo(170, 4));
  });

  test('weekend (Sat) has no office and still ends with sleep', () {
    final blocks = dayFor('2026-10-31');
    expectWellFormed(blocks);
    expect(blocks.where((b) => b.kind == RoutineKind.office), isEmpty);
    expect(blocks.where((b) => b.atOffice), isEmpty);
    expect(
      blocks.firstWhere((b) => b.kind == RoutineKind.training).title,
      contains('5K'),
    );
  });

  test('rituals are only included when chosen', () {
    final none = routineFor(
      a: a.copyWith(rituals: {}),
      date: '2026-10-26',
      proteinTargetG: 170,
    );
    expect(none.where((b) => b.kind == RoutineKind.ritual), isEmpty);
    expect(none.where((b) => b.kind == RoutineKind.focus), isEmpty);
    expectWellFormed(none);
  });

  test('currentBlock prefers the office-internal block', () {
    final blocks = dayFor('2026-10-26');
    expect(currentBlock(blocks, 11 * 60)!.kind, RoutineKind.focus);
    expect(currentBlock(blocks, 6 * 60 + 40)!.kind, RoutineKind.training);
  });
}
