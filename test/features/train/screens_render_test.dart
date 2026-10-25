import 'package:athlete_os/core/util/ids.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/train/data/workout_repository.dart';
import 'package:athlete_os/features/train/domain/run_review.dart';
import 'package:athlete_os/features/train/domain/running_models.dart';
import 'package:athlete_os/features/train/domain/workout_draft.dart';
import 'package:athlete_os/features/train/presentation/activity_detail_screen.dart';
import 'package:athlete_os/features/train/presentation/running_screen.dart';
import 'package:athlete_os/features/train/presentation/strength_screen.dart';
import 'package:athlete_os/features/train/presentation/widgets/strava_branding.dart';
import 'package:athlete_os/features/train/presentation/workout_detail_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

final now = DateTime(2026, 10, 25, 9);

Future<void> seed(AppDatabase db) async {
  final repo = WorkoutRepository(db);
  for (var i = 0; i < 4; i++) {
    await repo.upsertWorkout(
      id: stableId('manual', 'w$i'),
      source: i.isEven ? 'hevy' : 'manual',
      draft: WorkoutDraft(
        title: 'Upper',
        startAt: DateTime(2026, 10, 4 + i * 6, 18),
        endAt: DateTime(2026, 10, 4 + i * 6, 19),
        exercises: [
          ExerciseDraft(
            name: 'Bench Press',
            muscleGroup: 'chest',
            sets: [
              const SetDraft(type: 'warmup', weightKg: 60, reps: 10),
              SetDraft(weightKg: 90.0 + i * 2.5, reps: 5),
              SetDraft(weightKg: 90.0 + i * 2.5, reps: 5),
            ],
          ),
          const ExerciseDraft(
            name: 'Pull Up',
            sets: [SetDraft(reps: 8), SetDraft(reps: 7)],
          ),
        ],
      ),
    );
  }
  final splits = RunSplit.listToJson([
    for (var k = 0; k < 5; k++)
      RunSplit(distanceM: 1000, movingTimeS: 340 - k * 4, avgHr: 150.0 + k),
    const RunSplit(distanceM: 210, movingTimeS: 70),
  ]);
  Future<void> run(String id, String source, DateTime at, {String? s}) => db
      .into(db.cardioActivities)
      .insert(
        CardioActivitiesCompanion.insert(
          id: id,
          source: source,
          externalId: Value('ext-$id'),
          name: Value('Run $id'),
          sportType: 'run',
          startAt: at.toUtc(),
          localDate:
              '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}',
          distanceM: const Value(5210),
          movingTimeS: const Value(1690),
          elapsedTimeS: const Value(1720),
          avgHeartRate: const Value(152),
          splitsJson: Value(s),
          fetchedAt: Value(now.toUtc()),
        ),
      );
  await run('s1', 'strava', DateTime(2026, 10, 23, 7), s: splits);
  await run('h1', 'health_connect', DateTime(2026, 10, 23, 7, 1));
  await run('h2', 'health_connect', DateTime(2026, 10, 18, 7));
  await run('h3', 'health_connect', DateTime(2026, 10, 11, 7));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  testWidgets('StrengthScreen renders trends, muscles and exercises', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await seed(db);
    await tester.pumpWidget(
      testHarness(const StrengthScreen(), db: db, now: now),
    );
    await settle(tester);
    expect(find.text('Weekly volume'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Improving'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Improving'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Muscle sets'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Muscle sets'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('WorkoutDetailScreen shows sets, PRs and comparison', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await seed(db);
    await tester.pumpWidget(
      testHarness(
        WorkoutDetailScreen(id: stableId('manual', 'w3')),
        db: db,
        now: now,
      ),
    );
    await settle(tester);
    expect(find.text('Personal records'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Vs previous'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Vs previous'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('RunningScreen dedupes and shows Powered by Strava', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await seed(db);
    await tester.pumpWidget(
      testHarness(const RunningScreen(), db: db, now: now),
    );
    await settle(tester);
    expect(find.text('5K goal'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(PoweredByStrava),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('also in Health Connect'), findsOneWidget);
    // h1 is hidden as a duplicate of s1.
    expect(find.text('Run h1'), findsNothing);
    await finish(tester);
  });

  testWidgets('Strava activity: rule-based review, AI coach disabled', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await seed(db);
    await tester.pumpWidget(
      testHarness(
        const ActivityDetailScreen(id: 's1'),
        db: db,
        now: now,
      ),
    );
    await settle(tester);
    expect(find.byType(ViewOnStravaLink), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(kReviewLabel),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('Ask AI coach for a deeper review'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    final btn = tester.widget<HudButton>(
      find.widgetWithText(HudButton, 'Ask AI coach for a deeper review'),
    );
    expect(btn.onPressed, isNull);
    expect(find.textContaining('prohibit'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Health Connect activity: AI coach button enabled', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await seed(db);
    await tester.pumpWidget(
      testHarness(
        const ActivityDetailScreen(id: 'h2'),
        db: db,
        now: now,
      ),
    );
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Ask AI coach for a deeper review'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    final btn = tester.widget<HudButton>(
      find.widgetWithText(HudButton, 'Ask AI coach for a deeper review'),
    );
    expect(btn.onPressed, isNotNull);
    expect(find.byType(PoweredByStrava), findsNothing);
    await finish(tester);
  });
}
