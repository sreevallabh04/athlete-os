import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/health/application/health_providers.dart';
import 'package:athlete_os/features/health/data/fake_health_data_source.dart';
import 'package:athlete_os/features/health/data/health_repository.dart';
import 'package:athlete_os/features/health/data/health_settings.dart';
import 'package:athlete_os/features/health/domain/health_types.dart';
import 'package:athlete_os/features/health/presentation/health_overview_screen.dart';
import 'package:athlete_os/features/health/presentation/health_status_screen.dart';
import 'package:athlete_os/features/health/presentation/steps_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

final now = DateTime(2026, 10, 25, 15);

Widget harness(Widget child, AppDatabase db, FakeHealthDataSource fake) =>
    ProviderScope(
      overrides: [
        ...testOverrides(db, now: now),
        healthDataSourceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    );

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  late AppDatabase db;

  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('StepsScreen shows the unavailable state with setup + manual '
      'CTAs when steps cannot be accessed', (tester) async {
    tallScreen(tester);
    final fake = FakeHealthDataSource(status: HcSdkStatus.needsInstall);
    await tester.pumpWidget(harness(const StepsScreen(), db, fake));
    await settle(tester);

    expect(
      find.text('The app cannot currently access step data'),
      findsOneWidget,
    );
    expect(find.text('Set up Health Connect'), findsOneWidget);
    expect(find.text('Enter steps manually'), findsWidgets);
    // No fabricated number.
    expect(find.textContaining('of 10,000'), findsNothing);

    // Manual entry flow.
    await tester.tap(find.text('Enter steps manually').first);
    await settle(tester);
    await tester.enterText(find.byType(TextField), '4321');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('4,321'), findsWidgets); // ring + averages
    expect(find.text('of 10,000'), findsOneWidget);
    expect(find.text('Manual entry'), findsOneWidget);

    await finish(tester);
  });

  testWidgets('StepsScreen with Health Connect data shows ring, remaining, '
      'pace estimate and source', (tester) async {
    tallScreen(tester);
    final clock = FixedClock(now);
    final repo = HealthRepository(db, clock);
    final today = LocalDates.key(now);
    await repo.upsertDailySummary(
      localDate: today,
      type: HealthKeys.steps,
      value: 6500,
      unit: 'count',
      origin: HealthKeys.originHc,
      sources: 'Samsung Health',
    );
    await repo.upsertDailySummary(
      localDate: LocalDates.addDays(today, -1),
      type: HealthKeys.steps,
      value: 11000,
      unit: 'count',
      origin: HealthKeys.originHc,
    );
    await repo.setManualSteps(today, 9999);
    await HealthSettings(SettingsRepository(db))
        .setGroupEnabled(HealthGroup.activity, true);
    final fake = FakeHealthDataSource(granted: HcDataType.values.toSet());

    await tester.pumpWidget(harness(const StepsScreen(), db, fake));
    await settle(tester);

    expect(find.text('6,500'), findsOneWidget);
    expect(find.text('of 10,000'), findsOneWidget);
    expect(find.text('3,500'), findsOneWidget); // remaining
    expect(find.text('65%'), findsOneWidget);
    expect(find.textContaining('(estimate)'), findsOneWidget);
    expect(find.text('From Samsung Health'), findsOneWidget);
    expect(find.textContaining('9,999) is overridden'), findsOneWidget);
    expect(
      find.text('The app cannot currently access step data'),
      findsNothing,
    );
    expect(find.text('7-day average'), findsOneWidget);
    // Never claims live data.
    expect(find.textContaining('live', findRichText: true), findsNothing);

    await finish(tester);
  });

  testWidgets('HealthOverviewScreen separates not-permitted from no-data', (
    tester,
  ) async {
    tallScreen(tester);
    await HealthSettings(SettingsRepository(db))
        .setGroupEnabled(HealthGroup.heart, true);
    final fake = FakeHealthDataSource(
      granted: {HcDataType.heartRate, HcDataType.restingHeartRate},
    );
    await tester.pumpWidget(harness(const HealthOverviewScreen(), db, fake));
    await settle(tester);

    expect(find.text('No heart-rate data yet'), findsOneWidget);
    expect(find.text('Sleep data isn\'t shared'), findsOneWidget);
    expect(find.text('No weight entries in the last 90 days'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('HealthStatusScreen shows SDK status, permissions and setup', (
    tester,
  ) async {
    tallScreen(tester);
    final semantics = tester.ensureSemantics();
    final fake = FakeHealthDataSource(granted: {HcDataType.steps});
    await tester.pumpWidget(harness(const HealthStatusScreen(), db, fake));
    await settle(tester);

    expect(find.text('Available'), findsOneWidget);
    expect(find.text('Needs setup'), findsOneWidget);
    expect(find.text('Never'), findsOneWidget);
    // Capability matrix: granted but not yet shared vs not granted.
    expect(find.bySemanticsLabel('Steps: granted, paused'), findsOneWidget);
    expect(find.bySemanticsLabel('Distance: not granted'), findsOneWidget);
    expect(find.text('Open Health Connect settings'), findsOneWidget);
    // Phone-only setup path is spelled out.
    expect(find.text('Add a phone step counter'), findsOneWidget);
    await finish(tester);
    semantics.dispose();
  });
}
