import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/planning/presentation/competition_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  Future<void> pump(WidgetTester tester, AppDatabase db, DateTime now) async {
    tester.view.physicalSize = const Size(360, 7000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testHarness(const CompetitionScreen(), db: db, now: now),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('no competition shows a call to action and safety card', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await pump(tester, db, DateTime.utc(2026, 10, 25, 12));
    expect(find.text('Set your competition date'), findsOneWidget);
    expect(find.text('No competition set'), findsOneWidget);
    expect(find.text('Prep safely'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('countdown shows days and weeks in the event timezone', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await db
        .into(db.competitions)
        .insert(
          CompetitionsCompanion.insert(
            id: 'c1',
            name: 'State Classic',
            eventDate: '2026-12-06',
            tzName: 'UTC',
            location: const Value('Pune'),
            division: const Value("Men's Physique"),
            createdAt: Value(DateTime.utc(2026, 9, 13, 12)),
          ),
        );
    await db
        .into(db.competitionMilestones)
        .insert(
          CompetitionMilestonesCompanion.insert(
            id: 'm1',
            competitionId: 'c1',
            title: 'Register for the event',
            kind: const Value('checklist'),
            dueDate: const Value('2026-11-01'),
          ),
        );

    await pump(tester, db, DateTime.utc(2026, 10, 25, 12));

    expect(find.text('42'), findsOneWidget);
    expect(find.text('DAYS TO GO'), findsOneWidget);
    expect(find.text('6 weeks'), findsOneWidget);
    expect(find.text('Pune'), findsOneWidget);
    expect(find.text("Men's Physique"), findsOneWidget);
    // 42 of 84 prep days elapsed.
    expect(find.textContaining('50% of prep complete'), findsOneWidget);
    expect(find.text('Register for the event'), findsWidgets);
    expect(find.text('Add suggested checklist'), findsOneWidget);
    expect(find.text('No weight entries yet'), findsOneWidget);
    expect(find.textContaining('not fat or muscle changes'), findsOneWidget);
    expect(find.textContaining('never uploaded'), findsOneWidget);
    await teardown(tester);
  });
}
