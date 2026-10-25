import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/life/application/habit_providers.dart';
import 'package:athlete_os/features/life/application/mood_journal_providers.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/presentation/habits_screen.dart';
import 'package:athlete_os/features/life/presentation/journal_editor_screen.dart';
import 'package:athlete_os/features/life/presentation/mood_check_in_sheet.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import 'golden_helpers.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('complete a habit, check in mood, write a journal entry → rows '
      'persisted and providers reflect them', (tester) async {
    useTallView(tester, size: const Size(1080, 2400));
    final container = goldenContainer(db);
    final habitId = await HabitRepository(
      db,
      FixedClock(goldenNow),
    ).create(const HabitInput(name: 'Morning mobility'));

    // 1. Habit: one tap on the checklist.
    await tester.pumpWidget(hostIn(container, const HabitsScreen()));
    await pumpUntil(tester, find.text('Morning mobility'));
    expect(find.text('1 remaining today'), findsOneWidget);
    await tester.tap(find.byKey(Key('habit-check-$habitId')));
    await pumpUntil(tester, find.byTooltip('Undo Morning mobility'));

    final completions = await db.select(db.habitCompletions).get();
    expect(completions, hasLength(1));
    expect(completions.single.habitId, habitId);
    expect(completions.single.localDate, goldenToday);
    expect(completions.single.status, 'done');

    final board = await readAsync(
      tester,
      container,
      habitBoardProvider,
      until: (b) => b.doneToday == 1,
    );
    expect(board.remainingToday, 0);

    // 2. Mood check-in through the sheet.
    await tester.pumpWidget(
      hostIn(
        container,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMoodCheckIn(context),
                child: const Text('open check-in'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open check-in'));
    await pumpUntil(tester, find.byKey(const Key('mood-4')));
    await tester.pump(const Duration(milliseconds: 400)); // sheet entrance
    await tester.tap(find.byKey(const Key('mood-4')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Save check-in'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Save check-in'));
    await pumpFrames(tester, count: 4);
    expect(find.text('Save check-in'), findsNothing, reason: 'sheet closed');

    final moods = await db.select(db.moodEntries).get();
    expect(moods, hasLength(1));
    expect(moods.single.mood, 4);
    expect(moods.single.localDate, goldenToday);

    final todayMood = await readAsync(
      tester,
      container,
      todayMoodProvider,
      until: (m) => m != null,
    );
    expect(todayMood!.mood, 4);

    // 3. Journal: autosave after the debounce.
    await tester.pumpWidget(hostIn(container, const JournalEditorScreen()));
    await pumpUntil(tester, find.byKey(const Key('journal-body')));
    await tester.enterText(
      find.byKey(const Key('journal-body')),
      'Felt strong in training today.',
    );
    await tester.pump(const Duration(milliseconds: 900)); // 800 ms debounce
    await pumpFrames(tester, count: 3);

    final journals = await db.select(db.journalEntries).get();
    expect(journals, hasLength(1));
    expect(journals.single.body, 'Felt strong in training today.');
    expect(journals.single.localDate, goldenToday);

    expect(
      await readAsync(
        tester,
        container,
        journalWrittenTodayProvider,
        until: (v) => v,
      ),
      isTrue,
    );

    // Today snapshot sees all three.
    final snap = await readAsync(
      tester,
      container,
      todaySnapshotProvider,
      until: (s) => s.journalToday && s.moodToday != null,
    );
    expect(snap.habitCount, 1);
    expect(snap.habitTally.done, 1);
    expect(snap.habitTally.remaining, 0);
    expect(snap.moodToday!.mood, 4);
    expect(snap.journalToday, isTrue);

    await driftTeardown(tester);
    // Disposing the editor must not write a second journal row.
    expect(await db.select(db.journalEntries).get(), hasLength(1));
  });
}
