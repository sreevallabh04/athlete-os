import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/life/application/notifications/notification_providers.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/notification_prefs_repository.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:athlete_os/features/life/domain/reminder_kinds.dart';
import 'package:athlete_os/features/life/presentation/habits_screen.dart';
import 'package:athlete_os/features/life/presentation/journal_screen.dart';
import 'package:athlete_os/features/life/presentation/life_screen.dart';
import 'package:athlete_os/features/life/presentation/mood_screen.dart';
import 'package:athlete_os/features/life/presentation/notification_settings_screen.dart';
import 'package:athlete_os/features/life/presentation/suggested_habits_sheet.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'fake_notification_gateway.dart';

final now = DateTime(2026, 10, 25, 9);
const today = '2026-10-25';

/// Pumps until [finder] matches (drift streams resolve asynchronously).
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  group('HabitsScreen', () {
    testWidgets('empty state offers suggestions without pre-selection', (
      tester,
    ) async {
      await tester.pumpWidget(
        testHarness(const HabitsScreen(), db: db, now: now),
      );
      await pumpUntil(tester, find.text('No habits yet'));
      expect(find.text('Add suggested'), findsOneWidget);

      await tester.tap(find.text('Add suggested'));
      await pumpUntil(tester, find.text('Suggested habits'));
      final tiles = tester.widgetList<SuggestedHabitTile>(
        find.byType(SuggestedHabitTile),
      );
      expect(tiles, isNotEmpty);
      expect(tiles.every((b) => b.selected == false), isTrue);
      expect(find.text('Select habits to add'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('today checklist: one-tap complete, undo, and skip', (
      tester,
    ) async {
      final repo = HabitRepository(db, FixedClock(now));
      final read = await repo.create(const HabitInput(name: 'Read'));
      await repo.create(const HabitInput(name: 'Stretch'));

      await tester.pumpWidget(
        testHarness(const HabitsScreen(), db: db, now: now),
      );
      await pumpUntil(tester, find.text('Read'));
      expect(find.text('Stretch'), findsOneWidget);
      expect(find.text('2 remaining today'), findsOneWidget);

      // Complete with one tap.
      await tester.tap(find.byKey(Key('habit-check-$read')));
      await pumpUntil(tester, find.text('1 remaining today'));
      var rows = await repo.completions(habitId: read);
      expect(rows.single.status, 'done');
      expect(find.byTooltip('Undo Read'), findsOneWidget);

      // Tap again to undo.
      await tester.tap(find.byKey(Key('habit-check-$read')));
      await pumpUntil(tester, find.text('2 remaining today'));
      expect(await repo.completions(habitId: read), isEmpty);

      // Skip from the menu: allowed without penalty.
      await tester.tap(find.byTooltip('More for Read'));
      await pumpUntil(tester, find.text('Skip today'));
      await tester.pump(const Duration(milliseconds: 500)); // menu animation
      await tester.tap(find.text('Skip today'));
      await pumpUntil(tester, find.text('Read skipped today. No penalty.'));
      rows = await repo.completions(habitId: read);
      expect(rows.single.status, 'skipped');
      expect(rows.single.localDate, today);
      await settle(tester);
    });

    testWidgets('pending AI habit suggestion can be dismissed', (tester) async {
      await db
          .into(db.aiRecommendations)
          .insert(
            AiRecommendationsCompanion.insert(
              id: 'r1',
              kind: 'habit',
              content: 'Walk for 10 minutes after lunch',
            ),
          );
      await tester.pumpWidget(
        testHarness(const HabitsScreen(), db: db, now: now),
      );
      await pumpUntil(tester, find.text('Walk for 10 minutes after lunch'));
      await tester.tap(find.text('Dismiss'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Walk for 10 minutes after lunch'), findsNothing);
      final rec = await db.select(db.aiRecommendations).getSingle();
      expect(rec.status, 'dismissed');
      await settle(tester);
    });
  });

  group('LifeScreen', () {
    testWidgets('shows honest empty states and navigation tiles', (
      tester,
    ) async {
      await tester.pumpWidget(
        testHarness(const LifeScreen(), db: db, now: now),
      );
      await pumpUntil(tester, find.text('No habits yet'));
      await pumpUntil(tester, find.text('No check-in yet today'));
      await pumpUntil(tester, find.text('Nothing written today — optional'));
      for (final label in [
        'Planner',
        'Competition prep',
        'Reports',
        'Settings',
      ]) {
        await tester.scrollUntilVisible(find.text(label), 200);
        expect(find.text(label), findsOneWidget);
      }
      await settle(tester);
    });

    testWidgets('summarises today\'s habits', (tester) async {
      final repo = HabitRepository(db, FixedClock(now));
      final a = await repo.create(const HabitInput(name: 'A'));
      await repo.create(const HabitInput(name: 'B'));
      await repo.setStatus(a, today, HabitStatus.done);
      await tester.pumpWidget(
        testHarness(const LifeScreen(), db: db, now: now),
      );
      await pumpUntil(tester, find.text('1 done · 1 remaining'));
      await settle(tester);
    });
  });

  testWidgets('MoodScreen without data says so instead of inventing it', (
    tester,
  ) async {
    await tester.pumpWidget(testHarness(const MoodScreen(), db: db, now: now));
    await pumpUntil(tester, find.text('No check-in yet today'));
    await pumpUntil(tester, find.text('Not enough check-ins yet'));
    await tester.scrollUntilVisible(find.text('Mood vs sleep quality'), 200);
    expect(find.textContaining('Not enough data yet'), findsWidgets);
    await settle(tester);
  });

  testWidgets('Journal AI analysis stays off unless explicitly allowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      testHarness(const JournalScreen(), db: db, now: now),
    );
    await pumpUntil(tester, find.text('Nothing written yet'));
    expect(
      find.text('Off: journal text never leaves this device.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ai-journal-consent')));
    await pumpUntil(tester, find.text('Allow AI journal analysis?'));
    await tester.tap(find.text('Keep off'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.aiJournalConsent),
      isNull,
    );

    await tester.tap(find.byKey(const Key('ai-journal-consent')));
    await pumpUntil(tester, find.text('Allow'));
    await tester.tap(find.text('Allow'));
    await pumpUntil(
      tester,
      find.text('On: the AI coach may read entries when you ask it to.'),
    );
    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.aiJournalConsent),
      isTrue,
    );
    await settle(tester);
  });

  testWidgets('Notification settings: explains before asking for permission', (
    tester,
  ) async {
    final gateway = FakeNotificationGateway(enabled: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: now),
          notificationGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const NotificationSettingsScreen(),
        ),
      ),
    );
    await pumpUntil(tester, find.byKey(const Key('reminder-water')));
    expect(find.textContaining('Notifications are turned off'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reminder-water')));
    await pumpUntil(tester, find.text('Allow notifications?'));
    expect(gateway.permissionRequests, 0);
    await tester.tap(find.text('Continue'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(gateway.permissionRequests, 1);
    final prefs = await NotificationPrefsRepository(db, FixedClock(now)).all();
    expect(prefs[ReminderKind.water]!.enabled, isTrue);
    expect(prefs[ReminderKind.mood]!.enabled, isFalse);
    await settle(tester);
  });
}
