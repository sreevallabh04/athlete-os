// Regression tests for the engineering hardening pass (start-up budget,
// day rollover, timezone state, SQLite connection setup, log redaction,
// HUD frame pacing, late onboarding gate).
import 'dart:async';
import 'dart:io';

import 'package:athlete_os/app/bootstrap.dart';
import 'package:athlete_os/app/day_change.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/util/redact.dart';
import 'package:athlete_os/core/widgets/hud_background.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/coach/tools/life_tools.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/train/application/train_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../helpers/test_app.dart';

/// A clock the test can move.
class _MutableClock extends Clock {
  _MutableClock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
}

void main() {
  group('runBootstrapHooks', () {
    test('a slow hook never holds the first frame past the budget', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final slow = Completer<void>();
      var fastRan = false;
      final sw = Stopwatch()..start();
      await runBootstrapHooks(container, [
        (_) => slow.future, // hangs
        (_) async => fastRan = true,
      ], budget: const Duration(milliseconds: 150));
      sw.stop();
      expect(fastRan, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      slow.complete();
    });

    test(
      'hooks run concurrently and one failure does not stop the others',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final order = <String>[];
        final gate = Completer<void>();
        await runBootstrapHooks(container, [
          (_) async {
            order.add('a-start');
            await gate.future; // waits for b: only possible if concurrent
            order.add('a-end');
          },
          (_) async {
            order.add('b');
            gate.complete();
          },
          (_) async => throw StateError('boom'),
          (_) async => order.add('d'),
        ], budget: const Duration(seconds: 2));
        expect(order, containsAll(['a-start', 'b', 'a-end', 'd']));
      },
    );
  });

  group('local day rollover', () {
    test('day-scoped providers move to the new date at midnight', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final clock = _MutableClock(DateTime(2026, 10, 25, 23, 59, 30));
      final container = ProviderContainer(
        overrides: [
          ...testOverrides(db),
          clockProvider.overrideWithValue(clock),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(localDayProvider), '2026-10-25');
      expect(container.read(todayKeyProvider), '2026-10-25');
      expect(container.read(nutritionDateProvider), '2026-10-25');

      // Same day: refresh is a no-op.
      clock.value = DateTime(2026, 10, 25, 23, 59, 59);
      container.read(localDayProvider.notifier).refresh();
      expect(container.read(localDayProvider), '2026-10-25');

      clock.value = DateTime(2026, 10, 26, 0, 0, 2);
      final watcher = DayChangeWatcher(container);
      addTearDown(watcher.dispose);
      watcher.check(); // what the midnight timer / resume listener calls
      expect(container.read(localDayProvider), '2026-10-26');
      expect(container.read(todayKeyProvider), '2026-10-26');
      expect(container.read(nutritionDateProvider), '2026-10-26');
    });
  });

  group('timezone state', () {
    test('coach competition countdown never resets tz.local to UTC', () {
      if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
      final previous = tz.local;
      addTearDown(() => tz.setLocalLocation(previous));
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

      daysUntilEvent('2026-11-01', 'Europe/London', DateTime(2026, 10, 25, 9));

      expect(tz.local.name, 'Asia/Kolkata');
    });
  });

  group('SQLite connection setup', () {
    test('WAL + busy_timeout so two isolates can share the file', () {
      final dir = Directory.systemTemp.createTempSync('aos_db_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final raw = sqlite3.open('${dir.path}/t.sqlite');
      addTearDown(raw.close);
      AppDatabase.configureConnection(raw);
      expect(raw.select('PRAGMA journal_mode').first.values.first, 'wal');
      expect(raw.select('PRAGMA busy_timeout').first.values.first, 5000);
    });

    test('notification-isolate style second connection can write', () async {
      final dir = Directory.systemTemp.createTempSync('aos_db2_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final file = File('${dir.path}/athlete_os.sqlite');
      AppDatabase open() => AppDatabase.forTesting(
        NativeDatabase(file, setup: AppDatabase.configureConnection),
      );
      final main = open();
      addTearDown(main.close);
      // Main isolate holds an open read transaction-free connection.
      await main.select(main.waterLogs).get();
      final background = open();
      await WaterRepository(background, const Clock()).add(250);
      await background.close();
      expect((await main.select(main.waterLogs).get()).length, 1);
    });
  });

  test('redactSecrets drops bound SQL parameters (journal text etc.)', () {
    const e =
        'SqliteException(1555): while executing, UNIQUE constraint failed\n'
        '  Causing statement: INSERT INTO "journal_entries" ("id", "body") '
        'VALUES (?, ?), parameters: abc, my very private journal text';
    final out = redactSecrets(e);
    expect(out, isNot(contains('private journal')));
    expect(out, contains('UNIQUE constraint failed'));
    expect(out, endsWith('parameters: [REDACTED]'));
  });

  testWidgets('HUD background schedules frames at its fps, not every vsync', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: const HudBackground()),
    );
    await tester.pump(); // first tick paints and puts the ticker to sleep
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    // Half a 30 fps period later: still asleep (no frame requested).
    await tester.binding.delayed(const Duration(milliseconds: 15));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    // Once the period has passed the driver asks for exactly one frame...
    await tester.binding.delayed(const Duration(milliseconds: 25));
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
    // ...and goes back to sleep after painting it.
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a gate that loads after the first frame still redirects a '
      'first launch to onboarding', (tester) async {
    final db = newTestDb();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: testOverrides(db, now: DateTime(2026, 10, 25, 9)),
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(onboardingGateProvider), isNull);
    expect(router.state.uri.path, AppPaths.today);

    // Late load (start-up budget exceeded): drive it with fake time.
    unawaited(container.read(onboardingGateProvider.notifier).load());
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (container.read(onboardingGateProvider) != null) break;
    }
    expect(container.read(onboardingGateProvider), isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(router.state.uri.path, AppPaths.onboarding);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
