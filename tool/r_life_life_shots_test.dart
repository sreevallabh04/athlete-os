// Visual QA for the Life feature (r-life redesign): first-run and seeded
// states of every Life screen, one light-theme and one 1.3× text shot.
//
//   flutter test tool/r_life_life_shots_test.dart
//   flutter test tool/r_life_life_shots_test.dart --plain-name hub
//
// PNGs land in build/shots/r-life/life_*.png. Seed data is test-only.
import 'dart:async';

import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/journal_repository.dart';
import 'package:athlete_os/features/life/data/mood_repository.dart';
import 'package:athlete_os/features/life/data/notification_prefs_repository.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:athlete_os/features/life/domain/reminder_kinds.dart';
import 'package:athlete_os/features/life/domain/reminder_scheduler.dart';
import 'package:athlete_os/features/life/presentation/widgets/life_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots_test.dart';

final _now = DateTime(2026, 10, 25, 21, 40);
const _dir = 'r-life';

AppDatabase _db(WidgetTester t) => ProviderScope.containerOf(
  t.element(find.byType(AthleteOsApp)),
  listen: false,
).read(databaseProvider);

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < (ms / 50).ceil(); i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Runs [work] (started in the test's fake-async zone, like the app's own
/// DB streams) while pumping, so drift's lock is never held by a query that
/// can only finish on a pump — `runAsync` around writes would deadlock.
Future<void> _drive(WidgetTester t, Future<void> work) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    work.then(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  for (var i = 0; !done && i < 20000; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  if (!done) throw StateError('seeding did not finish');
}

String _day(int offset) => LocalDates.key(_now.add(Duration(days: offset)));

/// Six habits with a realistic month of history (misses and skips
/// included), three weeks of mood check-ins, four journal entries and a
/// few reminders switched on.
Future<void> seedLife(WidgetTester t) async {
  final db = _db(t);
  await _drive(
    t,
    db.transaction(() async {
      final start = FixedClock(_now.subtract(const Duration(days: 34)));
      final habits = HabitRepository(db, start);
      final ids = <String>[];
      for (final h in const [
        HabitInput(
          name: 'Morning mobility',
          category: HabitCategory.fitness,
          reminderTimes: [370],
        ),
        HabitInput(name: 'Read 20 pages', category: HabitCategory.mind),
        HabitInput(
          name: 'Train',
          category: HabitCategory.fitness,
          schedule: HabitSchedule.weekly(4),
        ),
        HabitInput(name: 'Hit 3.5 L water', category: HabitCategory.health),
        HabitInput(
          name: 'Meditate 10 min',
          category: HabitCategory.mind,
          schedule: HabitSchedule.custom(0x1F),
        ),
        HabitInput(
          name: 'Screens off by 22:30',
          category: HabitCategory.productivity,
        ),
      ]) {
        ids.add(await habits.create(h));
      }
      // Per-habit history over the last 33 days (today handled below).
      for (var i = 1; i <= 33; i++) {
        final d = _day(-i);
        final wd = LocalDates.parse(d).weekday;
        // Mobility: long streak (last 13 days clean), a skip and two misses
        // earlier.
        if (i == 20) {
          await habits.setStatus(ids[0], d, HabitStatus.skipped);
        } else if (i != 15 && i != 27) {
          await habits.setStatus(ids[0], d, HabitStatus.done);
        }
        // Reading: ~70 %.
        if ((i * 7) % 10 < 7) {
          await habits.setStatus(ids[1], d, HabitStatus.done);
        }
        // Train: Mon/Tue/Thu/Sat.
        if (wd == 1 || wd == 2 || wd == 4 || wd == 6) {
          await habits.setStatus(ids[2], d, HabitStatus.done);
        }
        // Water: mostly, a travel-day skip.
        if (i == 9) {
          await habits.setStatus(ids[3], d, HabitStatus.skipped);
        } else if (i % 6 != 0) {
          await habits.setStatus(ids[3], d, HabitStatus.done);
        }
        // Meditate: weekdays, misses on some.
        if (wd <= 5 && i % 4 != 1) {
          await habits.setStatus(ids[4], d, HabitStatus.done);
        }
        // Screens off: harder.
        if (i % 3 != 0) {
          await habits.setStatus(ids[5], d, HabitStatus.done);
        }
      }
      final today = _day(0);
      await habits.setStatus(ids[0], today, HabitStatus.done);
      await habits.setStatus(ids[1], today, HabitStatus.done);
      await habits.setStatus(ids[3], today, HabitStatus.skipped);

      // Mood: 3 weeks, a few days without a check-in.
      const moods = [
        4,
        3,
        4,
        5,
        4,
        2,
        3,
        4,
        4,
        5,
        3,
        4,
        2,
        3,
        4,
        5,
        4,
        4,
        3,
        4,
        4,
      ];
      for (var i = 20; i >= 0; i--) {
        if (i == 4 || i == 11 || i == 16) continue;
        final m = moods[20 - i];
        final at = _now
            .subtract(Duration(days: i))
            .copyWith(hour: i == 0 ? 9 : 21, minute: i == 0 ? 12 : 5);
        await MoodRepository(db, FixedClock(at)).add(
          MoodInput(
            mood: m,
            energy: (m + (i % 2)).clamp(1, 5),
            stress: (6 - m - (i % 3 == 0 ? 1 : 0)).clamp(1, 5),
            sleepQuality: (m - 1 + (i % 2)).clamp(1, 5),
            tags: [
              if (m >= 4) 'focused',
              if (m == 5) 'proud',
              if (m <= 2) 'tired',
              if (i % 5 == 0) 'grateful',
            ],
            note: i == 0
                ? 'Slept well, legs a bit heavy from yesterday.'
                : i == 7
                ? 'Long office day, skipped lunch walk.'
                : null,
          ),
        );
      }

      // Journal: four entries.
      final journal = [
        (
          -1,
          'Leg day went better than expected — hit 5×5 at 100 kg. Dal and '
              'paneer for dinner kept protein on track. Felt calm on the drive '
              'home.',
          'Mum\'s call in the evening.',
          'What went well today, even if it was small?',
        ),
        (
          -3,
          'Busy office day, back-to-back meetings until 18:30. Managed the '
              'evening walk anyway. Need to protect a focus block tomorrow '
              'morning.',
          null,
          null,
        ),
        (
          -6,
          'Rest day. Read for an hour and meal-prepped soya chunks and rice '
              'for the week.',
          'A quiet Sunday.',
          'What did your body need today? Did it get it?',
        ),
        (
          -12,
          'Sleep was rough, mood a bit low. Kept it simple: mobility, a light '
              'session, early night.',
          null,
          null,
        ),
      ];
      for (final (off, body, grat, prompt) in journal) {
        await JournalRepository(
          db,
          FixedClock(_now.add(Duration(days: off))),
        ).save(
          localDate: _day(off),
          body: body,
          gratitude: grat,
          prompt: prompt,
        );
      }

      // Reminders: a realistic few on, quiet hours 22:00 → 06:00.
      final prefs = NotificationPrefsRepository(db, FixedClock(_now));
      for (final k in [
        ReminderKind.water,
        ReminderKind.habit,
        ReminderKind.mood,
        ReminderKind.journal,
        ReminderKind.planning,
      ]) {
        await prefs.save(k, enabled: true);
      }
      await SettingsRepository(
        db,
      ).set(SettingKeys.quietHours, const QuietHours(22 * 60, 6 * 60).toJson());
    }),
  );
}

Future<void> _tap(WidgetTester t, Finder f, {int settle = 900}) async {
  await _pump(t, 600);
  await t.ensureVisible(f.first);
  await t.pump(const Duration(milliseconds: 50));
  await t.tap(f.first, warnIfMissed: false);
  await _pump(t, settle);
}

Future<void> _shot(
  WidgetTester t,
  String path,
  String name, {
  bool seed = false,
  int scrolls = 0,
  bool light = false,
  Future<void> Function(WidgetTester t)? then,
}) {
  LifeCelebrations.debugReset();
  return shotRoute(
    t,
    path,
    '$_dir/$name',
    now: _now,
    scrolls: scrolls,
    light: light,
    prepare: (t) async {
      if (seed) await seedLife(t);
      if (then != null) await then(t);
    },
  );
}

void main() {
  setUpAll(loadShotFonts);

  // ── First run ──
  testWidgets(
    'hub empty',
    (t) => _shot(t, '/life', 'life_hub_empty', scrolls: 1),
  );
  testWidgets('habits empty', (t) => _shot(t, '/habits', 'life_habits_empty'));
  testWidgets(
    'suggested sheet',
    (t) => _shot(
      t,
      '/habits',
      'life_suggested_sheet',
      then: (t) async {
        await _tap(t, find.text('Add suggested'));
        await _tap(t, find.text('Train'), settle: 300);
        await _tap(t, find.text('Log meals'), settle: 300);
      },
    ),
  );
  testWidgets(
    'editor new',
    (t) => _shot(
      t,
      '/habits',
      'life_editor_new',
      scrolls: 1,
      then: (t) => _tap(t, find.text('Create your own')),
    ),
  );
  testWidgets(
    'mood empty',
    (t) => _shot(t, '/mood', 'life_mood_empty', scrolls: 1),
  );
  testWidgets(
    'checkin sheet',
    (t) => _shot(
      t,
      '/life',
      'life_checkin_sheet',
      then: (t) async {
        await _tap(t, find.byKey(const Key('mood-4')).first);
      },
    ),
  );
  testWidgets(
    'journal empty',
    (t) => _shot(t, '/journal', 'life_journal_empty'),
  );
  testWidgets(
    'notifications empty',
    (t) => _shot(t, '/settings/notifications', 'life_notif_empty', scrolls: 1),
  );

  // ── Seeded ──
  testWidgets(
    'hub',
    (t) => _shot(t, '/life', 'life_hub', seed: true, scrolls: 1),
  );
  testWidgets(
    'habits',
    (t) => _shot(t, '/habits', 'life_habits', seed: true, scrolls: 1),
  );
  testWidgets(
    'habit detail',
    (t) => _shot(
      t,
      '/habits',
      'life_habit_detail',
      seed: true,
      scrolls: 1,
      then: (t) => _tap(t, find.text('Morning mobility')),
    ),
  );
  testWidgets(
    'editor edit',
    (t) => _shot(
      t,
      '/habits',
      'life_editor_edit',
      seed: true,
      then: (t) async {
        await _tap(t, find.text('Train'));
        await _tap(t, find.byTooltip('Edit habit'));
      },
    ),
  );
  testWidgets(
    'manage',
    (t) => _shot(
      t,
      '/habits',
      'life_manage',
      seed: true,
      then: (t) => _tap(t, find.byTooltip('Manage and reorder')),
    ),
  );
  testWidgets(
    'mood',
    (t) => _shot(t, '/mood', 'life_mood', seed: true, scrolls: 3),
  );
  testWidgets(
    'journal',
    (t) => _shot(t, '/journal', 'life_journal', seed: true, scrolls: 1),
  );
  testWidgets(
    'journal editor',
    (t) => _shot(
      t,
      '/journal',
      'life_journal_editor',
      seed: true,
      then: (t) => _tap(t, find.textContaining('Leg day went better')),
    ),
  );
  testWidgets(
    'journal focus',
    (t) => _shot(
      t,
      '/journal',
      'life_journal_focus',
      seed: true,
      then: (t) async {
        await _tap(t, find.textContaining('Leg day went better'));
        await _tap(t, find.byTooltip('Focus mode'));
      },
    ),
  );
  testWidgets(
    'notifications',
    (t) => _shot(
      t,
      '/settings/notifications',
      'life_notif',
      seed: true,
      scrolls: 4,
    ),
  );

  // ── Theme / accessibility ──
  testWidgets(
    'hub light',
    (t) => _shot(
      t,
      '/life',
      'life_hub_light',
      seed: true,
      light: true,
      scrolls: 1,
    ),
  );
  testWidgets('hub text 1.3', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await _shot(t, '/life', 'life_hub_text13', seed: true, scrolls: 1);
  });
  testWidgets('habits text 1.3', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await _shot(t, '/habits', 'life_habits_text13', seed: true);
  });
}
