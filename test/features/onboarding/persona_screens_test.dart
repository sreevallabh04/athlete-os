import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/health/data/health_repository.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/notification_prefs_repository.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/presentation/meal_ideas_sheet.dart';
import 'package:athlete_os/features/onboarding/presentation/program_screen.dart';
import 'package:athlete_os/features/onboarding/presentation/routine_screen.dart';
import 'package:athlete_os/features/planning/data/planning_repository.dart';
import 'package:athlete_os/features/train/presentation/log_workout_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

final monday = DateTime(2026, 10, 26, 9);

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

Future<void> calibrate(AppDatabase db) {
  final c = FixedClock(monday);
  final settings = SettingsRepository(db);
  return CalibrationService(
    profiles: ProfileRepository(db),
    settings: settings,
    habits: HabitRepository(db, c),
    prefs: NotificationPrefsRepository(db, c),
    planning: PlanningRepository(db, settings, c),
    health: HealthRepository(db, c),
    clock: c,
    db: db,
  ).engage(CalibrationAnswers.interviewDefaults());
}

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('Program screen: today\'s Push session, restriction swap, '
      'Start session pre-fills a manual workout', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await calibrate(db);
    {
      await PlanningRepository(
        db,
        SettingsRepository(db),
        FixedClock(monday),
      ).saveRestriction(
        description: 'Shoulder impingement',
        bodyPart: 'shoulder',
        clinicianImposed: false,
      );
    }
    await tester.pumpWidget(
      testHarness(const ProgramScreen(), db: db, now: monday),
    );
    await pumpUntil(tester, find.text('Push'));
    expect(find.textContaining('WEEK 1 · MON'), findsOneWidget);
    expect(find.textContaining('Incline Machine Press'), findsWidgets);
    expect(
      find.textContaining('Incline Dumbbell Press → Incline Machine Press'),
      findsOneWidget,
    );

    final start = find.widgetWithText(HudButton, 'Start session');
    await tester.scrollUntilVisible(start, 300);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(start);
    await pumpUntil(tester, find.byType(LogWorkoutScreen));
    expect(find.text('Log workout'), findsWidgets);
    expect(find.widgetWithText(TextField, 'Push'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Incline Machine Press'),
      findsOneWidget,
    );
    await settle(tester);
  });

  testWidgets('Program screen: Wednesday run shows pace zones', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await calibrate(db);
    await tester.pumpWidget(
      testHarness(const ProgramScreen(), db: db, now: monday),
    );
    await pumpUntil(tester, find.text('Push'));
    await tester.tap(find.text('Easy'));
    await pumpUntil(tester, find.text('Pace zones (estimates)'));
    expect(find.text('7:00–7:45/km'), findsWidgets);
    expect(find.text('6:00/km'), findsWidgets);
    await settle(tester);
  });

  testWidgets('Routine screen renders the day around the office', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 9000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await calibrate(db);
    await tester.pumpWidget(
      testHarness(const RoutineScreen(), db: db, now: monday),
    );
    await pumpUntil(tester, find.text('Office'));
    expect(find.text('Wake · 500 ml water'), findsOneWidget);
    expect(find.text('2000'), findsOneWidget); // kcal target tile
    await settle(tester);
  });

  testWidgets('What can I eat? opens ranked eggetarian ideas', (tester) async {
    await tester.pumpWidget(
      testHarness(
        const Scaffold(body: MealIdeasCard(kcalLeft: 900, proteinLeft: 90)),
        db: db,
        now: monday,
      ),
    );
    await tester.tap(find.text('What can I eat?'));
    await pumpUntil(tester, find.textContaining('Ranked by'));
    expect(find.textContaining('kcal'), findsWidgets);
    expect(find.textContaining('g P'), findsWidgets);
    await settle(tester);
  });
}
