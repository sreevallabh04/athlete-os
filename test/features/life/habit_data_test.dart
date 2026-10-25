import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/life/application/habit_providers.dart';
import 'package:athlete_os/features/life/data/auto_rule_repository.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/domain/auto_rules.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  final now = DateTime(2026, 10, 25, 18);
  const today = '2026-10-25';
  late AppDatabase db;
  late HabitRepository habits;
  late AutoRuleRepository auto;
  late HabitBoardLoader loader;

  setUp(() {
    db = newTestDb();
    habits = HabitRepository(db, FixedClock(now));
    auto = AutoRuleRepository(db);
    loader = HabitBoardLoader(db, habits, auto);
  });
  tearDown(() => db.close());

  Future<void> addSteps(
    String date,
    double value, {
    String origin = 'manual',
  }) => db
      .into(db.dailyHealthSummaries)
      .insert(
        DailyHealthSummariesCompanion.insert(
          localDate: date,
          type: 'steps',
          value: value,
          unit: 'count',
          origin: origin,
        ),
      );

  Future<void> addFood(String date, {bool deleted = false}) => db
      .into(db.foodLogEntries)
      .insert(
        FoodLogEntriesCompanion.insert(
          id: 'f-$date-${DateTime.now().microsecondsSinceEpoch}',
          name: 'Oats',
          mealType: 'breakfast',
          calories: 300,
          source: 'custom',
          verification: 'user_entered',
          loggedAt: DateTime.utc(2026, 10, 25, 8),
          localDate: date,
          tzName: 'UTC',
          deletedAt: Value(deleted ? DateTime.utc(2026, 10, 25) : null),
        ),
      );

  group('auto rules from DB data', () {
    test(
      'water goal uses profile waterGoalMl and ignores deleted logs',
      () async {
        final water = WaterRepository(db, FixedClock(now));
        await water.add(2000);
        final id = await water.add(1000);
        var days = await auto.daysBetween(today, today);
        expect(days[today]!.waterMl, 3000);
        expect(autoRuleMet(AutoRule.waterGoal, days[today]!), isTrue);
        await water.remove(id);
        days = await auto.daysBetween(today, today);
        expect(autoRuleMet(AutoRule.waterGoal, days[today]!), isFalse);
      },
    );

    test(
      'step goal uses the highest origin value; missing data is not met',
      () async {
        await addSteps(today, 6000, origin: 'manual');
        await addSteps(today, 10500, origin: 'health_connect');
        final met = await auto.metDates(AutoRule.stepGoal, '2026-10-24', today);
        expect(met, {today}); // 24th has no data → not met
      },
    );

    test('food logged requires a non-deleted entry', () async {
      await addFood('2026-10-24', deleted: true);
      await addFood(today);
      final met = await auto.metDates(AutoRule.foodLogged, '2026-10-24', today);
      expect(met, {today});
    });
  });

  group('habit board', () {
    test(
      'auto completion is shown as auto and never overrides manual',
      () async {
        final id = await habits.create(
          const HabitInput(name: 'Log meals', autoRule: AutoRule.foodLogged),
        );
        await addFood(today);
        var board = await loader.load(today);
        expect(board.habits.single.todayMark, const DayMark.done(auto: true));

        await habits.setStatus(id, today, HabitStatus.skipped);
        board = await loader.load(today);
        expect(board.habits.single.todayMark, const DayMark.skipped());

        // Undo restores the automatic state; the manual row is gone.
        await habits.clearStatus(id, today);
        board = await loader.load(today);
        expect(board.habits.single.todayMark?.auto, isTrue);
        expect(await habits.completions(habitId: id), isEmpty);
      },
    );

    test('today checklist counts and dependency suggestions', () async {
      final a = await habits.create(const HabitInput(name: 'Train'));
      await habits.create(HabitInput(name: 'Stretch', dependsOnHabitId: a));
      await habits.create(
        HabitInput(
          name: 'Mon only',
          schedule: HabitSchedule.custom(weekdayBit(1)),
        ),
      );
      var board = await loader.load(today);
      expect(board.dueToday.map((h) => h.name), ['Train', 'Stretch']);
      expect(board.notDueToday.map((h) => h.name), ['Mon only']);
      expect(board.remainingToday, 2);
      expect(
        board.habits.firstWhere((h) => h.name == 'Stretch').upNext,
        isFalse,
      );

      await habits.setStatus(a, today, HabitStatus.done);
      board = await loader.load(today);
      expect(board.doneToday, 1);
      final stretch = board.habits.firstWhere((h) => h.name == 'Stretch');
      expect(stretch.upNext, isTrue);
      expect(stretch.dependsOnName, 'Train');
    });

    test('reorder, archive and delete', () async {
      final a = await habits.create(const HabitInput(name: 'A'));
      final b = await habits.create(const HabitInput(name: 'B'));
      final c = await habits.create(HabitInput(name: 'C', dependsOnHabitId: a));
      await habits.reorder([c, a, b]);
      expect((await habits.habits()).map((h) => h.name), ['C', 'A', 'B']);
      await habits.setArchived(b, true);
      expect((await habits.habits()).map((h) => h.name), ['C', 'A']);
      expect((await habits.habits(includeArchived: true)).length, 3);
      await habits.delete(a);
      final left = await habits.habits(includeArchived: true);
      expect(left.map((h) => h.name), ['C', 'B']);
      expect(left.first.dependsOnHabitId, isNull);
    });

    test('setStatus replaces the existing status for the day', () async {
      final id = await habits.create(const HabitInput(name: 'Read'));
      await habits.setStatus(id, today, HabitStatus.done);
      await habits.setStatus(id, today, HabitStatus.skipped);
      final rows = await habits.completions(habitId: id);
      expect(rows.length, 1);
      expect(rows.single.status, 'skipped');
    });

    test('AI habit suggestions can be dismissed', () async {
      await db
          .into(db.aiRecommendations)
          .insert(
            AiRecommendationsCompanion.insert(
              id: 'r1',
              kind: 'habit',
              content: 'Walk 10 minutes after lunch',
            ),
          );
      await db
          .into(db.aiRecommendations)
          .insert(
            AiRecommendationsCompanion.insert(
              id: 'r2',
              kind: 'nutrition',
              content: 'Eat more fibre',
            ),
          );
      expect(
        (await habits.watchPendingHabitSuggestions().first).map((r) => r.id),
        ['r1'],
      );
      await habits.respondToSuggestion('r1', 'dismissed');
      expect(await habits.watchPendingHabitSuggestions().first, isEmpty);
    });
  });
}
