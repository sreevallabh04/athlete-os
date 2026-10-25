import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/today/presentation/today_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  final now = DateTime(2026, 10, 25, 9);

  Future<void> pumpToday(
    WidgetTester tester,
    AppDatabase db, {
    Size size = const Size(1280, 4200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(testHarness(const TodayScreen(), db: db, now: now));
    // Let drift streams emit and animations settle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('empty database shows honest empty/unavailable states', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await pumpToday(tester, db);

    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Set your competition date'), findsOneWidget);
    // Reactor: steps not synced, nutrition/water not logged; targets only.
    expect(find.text('NOT SYNCED'), findsOneWidget);
    expect(find.text('NOT LOGGED'), findsNWidgets(3));
    expect(find.text('Target 2,000'), findsOneWidget);
    expect(find.text('No workouts recorded yet'), findsOneWidget);
    expect(find.text('No runs since Monday'), findsOneWidget);
    expect(find.text('No sleep data'), findsOneWidget);
    expect(find.text('No heart-rate data'), findsOneWidget);
    expect(find.text('No priorities set for today.'), findsOneWidget);
    expect(find.text('Google Calendar is not connected.'), findsOneWidget);
    expect(find.text('No habits set up'), findsOneWidget);
    expect(find.text('Not checked in yet'), findsOneWidget);
    expect(
      find.text(
        'No program yet. Calibrate once and I will plan every '
        'session, deloads included.',
      ),
      findsOneWidget,
    );
    // The briefing idles honestly, and the sheet lists unavailable sources
    // instead of inventing numbers.
    expect(
      find.text('Nothing logged yet. Your targets are set and standing by.'),
      findsOneWidget,
    );
    await tester.tap(find.text('JARVIS · BRIEFING'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('NOT AVAILABLE YET'), findsOneWidget);
    expect(find.text('Ask JARVIS'), findsOneWidget);
    for (final chip in [
      'Steps',
      'Food log',
      'Water',
      'Calendar (not connected)',
      'Sleep',
    ]) {
      expect(find.text(chip), findsWidgets, reason: chip);
    }
    expect(find.textContaining('steps away'), findsNothing);
    expect(find.textContaining('to go'), findsNothing);
    expect(find.textContaining('kcal left'), findsNothing);
    expect(find.textContaining('bpm'), findsNothing);

    await teardown(tester);
  });

  testWidgets('seeded data shows correct remaining protein and steps', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await db
        .into(db.dailyHealthSummaries)
        .insert(
          DailyHealthSummariesCompanion.insert(
            localDate: '2026-10-25',
            type: 'steps',
            value: 8150,
            unit: 'count',
            origin: 'health_connect',
            computedAt: Value(now.subtract(const Duration(minutes: 12))),
          ),
        );
    Future<void> food(String id, String meal, double kcal, double p) => db
        .into(db.foodLogEntries)
        .insert(
          FoodLogEntriesCompanion.insert(
            id: id,
            name: 'Food $id',
            mealType: meal,
            calories: kcal,
            proteinG: Value(p),
            carbsG: const Value(50),
            fatG: const Value(10),
            source: 'custom',
            verification: 'user_entered',
            loggedAt: now.subtract(const Duration(hours: 1)).toUtc(),
            localDate: '2026-10-25',
            tzName: 'UTC',
          ),
        );
    await food('a', 'breakfast', 450, 40);
    await food('b', 'breakfast', 300, 22);
    await food('c', 'snack', 250, 30);
    await db
        .into(db.waterLogs)
        .insert(
          WaterLogsCompanion.insert(
            id: 'w',
            amountMl: 750,
            loggedAt: now.toUtc(),
            localDate: '2026-10-25',
          ),
        );
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 't1',
            title: 'Book tan appointment',
            localDate: '2026-10-25',
            priority: const Value(1),
          ),
        );
    await db
        .into(db.competitions)
        .insert(
          CompetitionsCompanion.insert(
            id: 'c1',
            name: 'State Classic',
            eventDate: '2026-12-06',
            tzName: 'Asia/Kolkata',
          ),
        );

    await pumpToday(tester, db);

    // Reactor legend: real remaining amounts.
    expect(find.text('1,850 to go'), findsOneWidget); // steps
    expect(find.text('58 g to go'), findsOneWidget); // protein
    expect(find.text('1,000 left'), findsOneWidget); // calories
    expect(find.text('Book tan appointment'), findsOneWidget);
    expect(find.text('42'), findsOneWidget); // competition countdown
    expect(find.text('NOT SYNCED'), findsNothing);

    // Calories detail: meals logged (breakfast + snack).
    await tester.tap(find.text('CALORIES'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.textContaining('2 meals · 3 items'), findsOneWidget);

    // The full briefing has every deterministic sentence.
    await tester.tap(find.text('JARVIS · BRIEFING'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      find.text(
        "You're 1,850 steps away from your 10,000 goal (Health Connect, 12 min ago).",
      ),
      findsOneWidget,
    );
    expect(
      find.text("You've logged 92 g protein — 58 g to go."),
      findsNWidgets(2), // briefing strip lead + full briefing sheet
    );
    expect(find.text('42 days to State Classic.'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('phone width renders all sections without overflow', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await db
        .into(db.competitions)
        .insert(
          CompetitionsCompanion.insert(
            id: 'c1',
            name: 'Regional Mens Physique Championship',
            eventDate: '2026-10-25',
            tzName: 'Europe/London',
            location: const Value('Birmingham'),
          ),
        );
    await pumpToday(tester, db, size: const Size(360, 5200));
    expect(find.text('SHOW DAY'), findsOneWidget);
    expect(find.textContaining('Show day. Good luck.'), findsOneWidget);
    for (final label in [
      'DAILY TARGETS',
      'HABITS',
      'TOP 3 PRIORITIES',
      'AGENDA',
      'VITALS',
      'CHECK-INS',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('+250 ml quick action logs water and offers undo', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await pumpToday(tester, db);
    await tester.tap(find.text('+250 ml'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final rows = await db.select(db.waterLogs).get();
    expect(rows.single.amountMl, 250);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('2.8 L to go'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('priorities toggle inline', (tester) async {
    final db = newTestDb();
    addTearDown(db.close);
    await db
        .into(db.tasks)
        .insert(
          TasksCompanion.insert(
            id: 't1',
            title: 'Book posing coach',
            localDate: '2026-10-25',
          ),
        );
    await pumpToday(tester, db);
    await tester.tap(find.text('Book posing coach'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final t = await (db.select(
      db.tasks,
    )..where((r) => r.id.equals('t1'))).getSingle();
    expect(t.done, isTrue);
    await teardown(tester);
  });
}
