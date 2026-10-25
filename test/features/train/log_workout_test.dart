import 'package:athlete_os/core/haptics/haptics.dart';
import 'package:athlete_os/features/train/domain/workout_draft.dart';
import 'package:athlete_os/features/train/presentation/log_workout_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('ticking a set starts the reactor rest timer; it fires a haptic '
      'and flips to "rest done" at zero', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final events = <String>[];
    Haptics.debugOnEvent = events.add;
    addTearDown(() => Haptics.debugOnEvent = null);

    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(
        LogWorkoutScreen(
          initial: WorkoutDraft(
            title: 'Push',
            startAt: DateTime(2026, 10, 26, 6, 30),
            exercises: const [
              ExerciseDraft(
                name: 'Cable Lateral Raise',
                sets: [SetDraft(), SetDraft()],
              ),
            ],
          ),
          restSeconds: const [60],
        ),
        db: db,
        now: DateTime(2026, 10, 26, 6, 30),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('RESTING'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'kg').first, '10');
    await tester.enterText(find.widgetWithText(TextField, 'reps').first, '15');
    await tester.tap(find.bySemanticsLabel('Set 1 done'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('RESTING'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget); // live set counter
    expect(events, contains('medium'));

    // +15 s extends the countdown (60 + 15 s).
    await tester.tap(find.text('+15'));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('RESTING'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('REST DONE'), findsOneWidget);
    expect(events, contains('goalReached'));

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
