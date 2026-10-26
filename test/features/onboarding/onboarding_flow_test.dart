import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/widgets/dock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/health/data/health_repository.dart';
import 'package:athlete_os/features/life/application/notifications/notification_providers.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/notification_prefs_repository.dart';
import 'package:athlete_os/features/life/domain/reminder_kinds.dart';
import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/onboarding/data/calibration_service.dart';
import 'package:athlete_os/features/onboarding/data/nutrition_adjustment_service.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:athlete_os/features/onboarding/domain/training_program.dart';
import 'package:athlete_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:athlete_os/features/planning/data/planning_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import '../life/fake_notification_gateway.dart';

final now = DateTime(2026, 10, 25, 9); // Sunday

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

CalibrationService serviceFor(AppDatabase db) {
  final c = FixedClock(now);
  final settings = SettingsRepository(db);
  return CalibrationService(
    profiles: ProfileRepository(db),
    settings: settings,
    habits: HabitRepository(db, c),
    prefs: NotificationPrefsRepository(db, c),
    planning: PlanningRepository(db, settings, c),
    health: HealthRepository(db, c),
    clock: c,
    db: db,
  );
}

class _FixedGate extends OnboardingGate {
  _FixedGate(this.value);
  final bool? value;
  @override
  bool? build() => value;
}

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('prefilled wizard → Skip → Engage persists the calibration', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final gateway = FakeNotificationGateway();
    var finished = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: now),
          notificationGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: OnboardingScreen(onFinished: () => finished = true),
        ),
      ),
    );
    await pumpUntil(tester, find.text('Begin calibration'));
    expect(find.text('Good to meet you properly.'), findsOneWidget);

    // Step 2 shows the pre-filled name.
    await tester.tap(find.text('Begin calibration'));
    await pumpUntil(tester, find.text('What should I call you?'));
    expect(find.text('Sreevallabh'), findsWidgets);

    // Nothing has been written yet.
    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.onboardingDone),
      isNull,
    );
    expect(await ProfileRepository(db).history(), isEmpty);

    await tester.tap(find.text('Skip'));
    await pumpUntil(tester, find.text('Engage'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2,000 kcal'), findsOneWidget);
    expect(find.text('170'), findsWidgets);

    await tester.tap(find.text('Engage'));
    for (var i = 0; i < 300 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finished, isTrue);

    final p = await ProfileRepository(db).get();
    expect(p.displayName, 'Sreevallabh');
    expect(p.calorieTarget, 2000);
    expect(p.proteinTargetG, 170);
    expect(p.fatTargetG, 65);
    expect(p.carbsTargetG, 185);
    expect(p.stepGoal, 12000);
    expect(p.waterGoalMl, 3500);
    expect(p.wakeMinutes, 360);
    expect(p.sleepMinutes, 1350);
    expect(p.dietType, 'eggetarian');

    final history = await ProfileRepository(db).history();
    expect(history, isNotEmpty);
    expect(history.every((h) => h.reason == 'JARVIS calibration'), isTrue);
    expect(history.every((h) => h.changedBy == 'user'), isTrue);
    // 2,000 kcal equals the schema default, so carbs is the target that
    // visibly changes on Engage.
    expect(history.map((h) => h.metric), contains('carbsTargetG'));

    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.onboardingDone),
      isTrue,
    );
    final program = TrainingProgram.fromJson(
      await SettingsRepository(db).get<Object?>(PersonaKeys.program),
    );
    expect(program, isNotNull);
    expect(program!.startDate, '2026-10-19');

    final prefs = await NotificationPrefsRepository(db, FixedClock(now)).all();
    expect(prefs[ReminderKind.mood]!.enabled, isTrue);
    expect(prefs[ReminderKind.mood]!.config.times, [1290]);
    expect(prefs[ReminderKind.journal]!.config.times, [1320]);
    expect(prefs[ReminderKind.planning]!.config.times, [375]);
    expect(prefs[ReminderKind.eodReview]!.config.times, [1305]);
    expect(prefs[ReminderKind.water]!.config.intervalMinutes, 90);
    expect(prefs[ReminderKind.workout]!.config.times, [360]);
    expect(prefs[ReminderKind.workout]!.config.daysMask, 127);
    expect(prefs[ReminderKind.meal]!.enabled, isFalse);
    expect(prefs[ReminderKind.steps]!.enabled, isFalse);
    expect(prefs[ReminderKind.posing]!.enabled, isFalse);
    expect(gateway.permissionRequests, 1);

    final habits = await HabitRepository(db, FixedClock(now)).habits();
    expect(habits.map((h) => h.name), contains('Hit step goal'));
    expect(habits.map((h) => h.name), isNot(contains('Reach protein target')));
    await settle(tester);
  });

  testWidgets('every wizard step renders with pre-filled answers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: now),
          notificationGatewayProvider.overrideWithValue(
            FakeNotificationGateway(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const OnboardingScreen(),
        ),
      ),
    );
    await pumpUntil(tester, find.text('Begin calibration'));
    await tester.tap(find.text('Begin calibration'));
    for (var i = 2; i < 18; i++) {
      await pumpUntil(tester, find.text('Step $i of 18'));
      if (i == 7) {
        expect(find.text('78 kg', findRichText: true), findsOneWidget);
      }
      if (i == 12) {
        expect(find.text('12000', findRichText: true), findsOneWidget);
      }
      await tester.tap(find.text('Next'));
    }
    await pumpUntil(tester, find.text('Engage'));
    expect(find.text('Step 18 of 18'), findsOneWidget);
    // Back returns to the previous question without losing answers.
    await tester.tap(find.byTooltip('Back'));
    await pumpUntil(tester, find.text('Wearable status?'));
    expect(
      await SettingsRepository(db).get<bool>(SettingKeys.onboardingDone),
      isNull,
    );
    await settle(tester);
  });

  group('CalibrationService', () {
    test(
      'only chosen reminder kinds are enabled; re-run is idempotent',
      () async {
        final service = serviceFor(db);
        final a = CalibrationAnswers.interviewDefaults().copyWith(
          rituals: {Ritual.moodCheckIn},
          habits: {SeedHabit.stepGoal},
        );
        final r1 = await service.engage(a);
        expect(r1.remindersEnabled, [ReminderKind.mood]);
        final prefs = await NotificationPrefsRepository(
          db,
          FixedClock(now),
        ).all();
        final on = [
          for (final e in prefs.entries)
            if (e.value.enabled) e.key,
        ];
        expect(on, [ReminderKind.mood]);
        expect(r1.habitsCreated, ['Hit step goal']);
        expect(r1.competitionId, isNull);

        // Recalibrate: switch mood off, journal on; habits are not duplicated.
        final r2 = await service.engage(
          a.copyWith(
            rituals: {Ritual.journal},
            competitionDate: () => '2027-04-10',
          ),
        );
        expect(r2.habitsCreated, isEmpty);
        final prefs2 = await NotificationPrefsRepository(
          db,
          FixedClock(now),
        ).all();
        expect(prefs2[ReminderKind.mood]!.enabled, isFalse);
        expect(prefs2[ReminderKind.journal]!.enabled, isTrue);
        expect(r2.competitionId, isNotNull);
        final comp = await PlanningRepository(
          db,
          SettingsRepository(db),
          FixedClock(now),
        ).primaryCompetition();
        expect(comp!.eventDate, '2027-04-10');
        expect(comp.division, 'Men\'s Physique');

        // One weigh-in for the day, not one per run.
        final weights = await (db.select(
          db.healthSamples,
        )..where((s) => s.type.equals('weight'))).get();
        expect(weights, hasLength(1));
        expect(weights.single.value, 78);
      },
    );

    test('calibration answers round-trip through JSON', () {
      final a = CalibrationAnswers.interviewDefaults().copyWith(
        competitionDate: () => '2027-03-01',
        rituals: {Ritual.water},
      );
      final b = CalibrationAnswers.fromJson(a.toJson());
      expect(b.toJson(), a.toJson());
    });
  });

  group('NutritionAdjustmentService', () {
    test('proposes once per week and applies only on accept', () async {
      await serviceFor(db).engage(CalibrationAnswers.interviewDefaults());
      final health = HealthRepository(db, FixedClock(now));
      // Calibration logged today's 78 kg; flat trend for two weeks.
      for (var d = 1; d <= 13; d++) {
        await health.addManualWeight(78, at: now.subtract(Duration(days: d)));
      }
      final svc = NutritionAdjustmentService(
        db: db,
        profiles: ProfileRepository(db),
        settings: SettingsRepository(db),
        clock: FixedClock(now),
      );
      final r = await svc.evaluate();
      expect(r.deltaKcal, -150);
      await svc.evaluate(); // idempotent per week
      final pending = await svc.watchPending().first;
      expect(pending, hasLength(1));
      expect(pending.single.kind, 'nutrition');
      expect((await ProfileRepository(db).get()).calorieTarget, 2000);

      await svc.accept(pending.single.id);
      final p = await ProfileRepository(db).get();
      expect(p.calorieTarget, 1850);
      expect(p.proteinTargetG, 170);
      final approved = (await ProfileRepository(
        db,
      ).history()).where((h) => h.changedBy == 'ai_approved').toList();
      expect(approved.map((h) => h.metric), contains('calorieTarget'));
      expect(approved.first.reason, contains('Weekly nutrition adjustment'));
      expect(await svc.watchPending().first, isEmpty);
    });
  });

  group('first-launch redirect', () {
    test('redirects only when onboarding is known to be not done', () {
      expect(
        onboardingRedirectFor(done: false, path: AppPaths.today),
        AppPaths.onboarding,
      );
      expect(
        onboardingRedirectFor(done: false, path: AppPaths.onboarding),
        isNull,
      );
      expect(onboardingRedirectFor(done: true, path: AppPaths.today), isNull);
      expect(onboardingRedirectFor(done: null, path: AppPaths.today), isNull);
    });

    Future<void> boot(WidgetTester tester, bool done) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...testOverrides(db, now: now),
            onboardingGateProvider.overrideWith(() => _FixedGate(done)),
            notificationGatewayProvider.overrideWithValue(
              FakeNotificationGateway(),
            ),
          ],
          child: const AthleteOsApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('first launch opens JARVIS calibration', (tester) async {
      await boot(tester, false);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(HudDock), findsNothing);
      await settle(tester);
    });

    testWidgets('after onboarding the app opens on Today', (tester) async {
      await boot(tester, true);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(HudDock), findsOneWidget);
      await settle(tester);
    });

    test('gate loads onboarding_done from settings', () async {
      final container = ProviderContainer(overrides: testOverrides(db));
      addTearDown(container.dispose);
      await container.read(onboardingGateProvider.notifier).load();
      expect(container.read(onboardingGateProvider), isFalse);
      await SettingsRepository(db).set(SettingKeys.onboardingDone, true);
      await container.read(onboardingGateProvider.notifier).load();
      expect(container.read(onboardingGateProvider), isTrue);
    });
  });
}
