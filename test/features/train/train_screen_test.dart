import 'package:athlete_os/core/util/ids.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:athlete_os/features/train/presentation/log_workout_screen.dart';
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

  testWidgets('with a program: week HUD, today session and one-tap start', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final db = newTestDb();
    addTearDown(db.close);
    await SettingsRepository(db).set(
      PersonaKeys.program,
      generateMensPhysiqueProgram(startMonday: '2026-10-19').toJson(),
    );
    await tester.pumpWidget(
      testHarness(
        const TrainScreen(),
        db: db,
        now: DateTime(2026, 10, 23, 6, 5), // Friday: Upper · V-taper
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('Upper · V-taper'), findsOneWidget);
    expect(find.text('0/5'), findsOneWidget); // lifts done this week
    // First run: compact setup card, never a fabricated PR or number.
    expect(find.text('No training data yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(HudButton, 'Start session'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(LogWorkoutScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Upper · V-taper'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
