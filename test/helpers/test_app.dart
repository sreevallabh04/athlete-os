import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/providers.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// Fresh in-memory database for a test.
AppDatabase newTestDb() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase.forTesting(NativeDatabase.memory());
}

/// Provider overrides for an isolated test environment.
List<Override> testOverrides(AppDatabase db, {DateTime? now}) => [
  databaseProvider.overrideWithValue(db),
  if (now != null) clockProvider.overrideWithValue(FixedClock(now)),
];

/// Wraps [child] in theme + ProviderScope for widget tests.
Widget testHarness(Widget child, {required AppDatabase db, DateTime? now}) =>
    ProviderScope(
      overrides: testOverrides(db, now: now),
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    );
