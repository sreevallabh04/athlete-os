import 'package:athlete_os/core/util/ids.dart';
import 'package:athlete_os/features/train/data/workout_repository.dart';
import 'package:athlete_os/features/train/domain/workout_draft.dart';
import 'package:athlete_os/features/train/presentation/train_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('empty state guides to connecting apps or logging manually', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(const TrainScreen(), db: db, now: DateTime(2026, 10, 25, 9)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('No training data yet'), findsOneWidget);
    expect(find.text('Connect apps'), findsOneWidget);
    expect(find.text('Log manually'), findsOneWidget);
    expect(find.text('Import CSV'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('shows this week and the latest workout', (tester) async {
    final db = newTestDb();
    addTearDown(db.close);
    await WorkoutRepository(db).upsertWorkout(
      id: stableId('manual', 'x'),
      source: 'manual',
      draft: WorkoutDraft(
        title: 'Upper A',
        startAt: DateTime(2026, 10, 24, 18),
        endAt: DateTime(2026, 10, 24, 19),
        exercises: const [
          ExerciseDraft(
            name: 'Bench Press',
            sets: [
              SetDraft(type: 'warmup', weightKg: 60, reps: 10),
              SetDraft(weightKg: 100, reps: 5),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      testHarness(const TrainScreen(), db: db, now: DateTime(2026, 10, 25, 9)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Upper A'), findsOneWidget);
    expect(find.textContaining('500 kg'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
