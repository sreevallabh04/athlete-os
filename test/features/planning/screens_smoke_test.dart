import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/planning/presentation/planner_screen.dart';
import 'package:athlete_os/features/planning/presentation/privacy_data_screen.dart';
import 'package:athlete_os/features/planning/presentation/profile_goals_screen.dart';
import 'package:athlete_os/features/planning/presentation/reports_screen.dart';
import 'package:athlete_os/features/planning/presentation/settings_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  final now = DateTime(2026, 10, 25, 9);

  Future<AppDatabase> pump(WidgetTester tester, Widget screen) async {
    final db = newTestDb();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(360, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(testHarness(screen, db: db, now: now));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return db;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  testWidgets('settings lists every section', (tester) async {
    await pump(tester, const SettingsScreen());
    for (final s in [
      'Profile & goals',
      'Notifications',
      'Integrations',
      'AI providers',
      'Coach memory',
      'AI activity log',
      'Privacy & data',
      'Open-source licenses',
      'Powered by Strava',
    ]) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await teardown(tester);
  });

  testWidgets('planner shows empty priorities, free time and disabled AI', (
    tester,
  ) async {
    await pump(tester, const PlannerScreen());
    expect(find.text('No priorities yet'), findsOneWidget);
    expect(
      find.textContaining('Google Calendar is not connected'),
      findsOneWidget,
    );
    expect(find.text('Suggested blocks'), findsOneWidget);
    final coach = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Ask coach to plan my day'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton),
      ),
    );
    expect(coach.onPressed, isNull);
    await teardown(tester);
  });

  testWidgets('planner offers yesterday\'s unfinished tasks explicitly', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'y1',
            title: 'Call physio',
            localDate: '2026-10-24',
          ),
        );
    tester.view.physicalSize = const Size(360, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testHarness(const PlannerScreen(), db: db, now: now),
    );
    await settle(tester);
    expect(
      find.textContaining('1 unfinished priority from yesterday'),
      findsOneWidget,
    );
    // Nothing moved automatically.
    final today = await (db.select(
      db.tasks,
    )..where((t) => t.localDate.equals('2026-10-25'))).get();
    expect(today, isEmpty);
    await tester.tap(find.text('Review'));
    await settle(tester);
    await tester.tap(find.text('Carry over 1'));
    await settle(tester);
    final moved = await (db.select(
      db.tasks,
    )..where((t) => t.id.equals('y1'))).getSingle();
    expect(moved.localDate, '2026-10-25');
    expect(moved.carriedFromDate, '2026-10-24');
    await teardown(tester);
  });

  testWidgets('reports generate on demand with rule-based insights', (
    tester,
  ) async {
    final db = await pump(tester, const ReportsScreen());
    await db
        .into(db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: 'f',
            name: 'Paneer bowl',
            mealType: 'lunch',
            calories: 650,
            proteinG: const Value(45),
            source: 'custom',
            verification: 'user_entered',
            loggedAt: now.toUtc(),
            localDate: '2026-10-25',
            tzName: 'UTC',
          ),
        );
    await tester.tap(find.text('Generate report'));
    await settle(tester);
    expect(find.text('Most important improvement'), findsOneWidget);
    expect(find.text('Suggested focus for next week'), findsOneWidget);
    expect(find.text('Rule-based'), findsNWidgets(2));
    expect(find.text('Avg calories'), findsOneWidget);
    expect(find.text('650 kcal'), findsOneWidget);
    expect(find.text('No step data in this period.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets(
    'profile target change requires confirmation with diff and caution',
    (tester) async {
      final db = await pump(tester, const ProfileGoalsScreen());
      final kcal = find.widgetWithText(TextFormField, 'Calories');
      expect(kcal, findsOneWidget);
      await tester.enterText(kcal, '1400');
      await tester.tap(find.text('Save changes'));
      await settle(tester);
      expect(find.text('Confirm target changes'), findsOneWidget);
      expect(find.text('2000 → 1400'), findsOneWidget);
      expect(find.textContaining('below 1,500 kcal'), findsOneWidget);
      // Cancel: nothing changes.
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(
        (await db.select(db.userProfiles).getSingle()).calorieTarget,
        2000,
      );
      // Confirm: saved and logged to goal history.
      await tester.tap(find.text('Save changes'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes').last);
      await settle(tester);
      expect(
        (await db.select(db.userProfiles).getSingle()).calorieTarget,
        1400,
      );
      final history = await db.select(db.goalHistory).get();
      expect(history.single.metric, 'calorieTarget');
      await teardown(tester);
    },
  );

  testWidgets(
    'privacy screen shows consents off by default and delete controls',
    (tester) async {
      await pump(tester, const PrivacyDataScreen());
      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches, hasLength(3));
      expect(switches.every((s) => !s.value), isTrue);
      expect(find.text('Delete everything'), findsOneWidget);
      expect(find.text('Export JSON'), findsOneWidget);
      await tester.tap(find.text('Delete journal entries'));
      await settle(tester);
      final del = find.widgetWithText(FilledButton, 'Delete permanently');
      expect(tester.widget<FilledButton>(del).onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, 'DELETE');
      await tester.pump();
      expect(tester.widget<FilledButton>(del).onPressed, isNotNull);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      await teardown(tester);
    },
  );
}
