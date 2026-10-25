import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/core/util/format.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/life/application/notifications/notification_providers.dart';
import 'package:athlete_os/features/onboarding/application/persona_providers.dart';
import 'package:athlete_os/features/onboarding/bootstrap.dart';
import 'package:athlete_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:athlete_os/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/life/fake_notification_gateway.dart';
import '../helpers/test_app.dart';
import 'golden_helpers.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets(
    'fresh install → calibration → Engage → Today shows the computed targets',
    (tester) async {
      useTallView(tester, size: const Size(1080, 4200));
      final container = goldenContainer(
        db,
        extra: [
          notificationGatewayProvider.overrideWithValue(
            FakeNotificationGateway(),
          ),
        ],
      );

      // Same start-up path as main(): the gate is loaded before first frame.
      await onboardingBootstrap(container);
      expect(container.read(onboardingGateProvider), isFalse);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const AthleteOsApp(),
        ),
      );
      await pumpUntil(tester, find.text('Begin calibration'));
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);

      await tester.tap(find.text('Begin calibration'));
      await pumpUntil(tester, find.text('Skip'));
      await tester.tap(find.text('Skip'));
      await pumpUntil(tester, find.text('Engage'));
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('Engage'));

      // Engage persists the calibration, then the router hands over to Today.
      await pumpUntil(tester, find.byType(TodayScreen), maxSteps: 300);
      await pumpFrames(tester);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(container.read(onboardingGateProvider), isTrue);
      expect(
        await SettingsRepository(db).get<bool>(SettingKeys.onboardingDone),
        isTrue,
      );

      // The profile was computed by the calibration (not the seed defaults).
      final p = await ProfileRepository(db).get();
      expect(p.calorieTarget, 2250);
      expect(p.proteinTargetG, 170);
      expect(p.waterGoalMl, 3500);
      expect(p.stepGoal, 12000);

      // Today's snapshot and the reactor legend show exactly those targets.
      final snap = await readAsync(tester, container, todaySnapshotProvider);
      expect(snap.profile.calorieTarget, p.calorieTarget);
      expect(snap.profile.proteinTargetG, p.proteinTargetG);
      expect(snap.profile.waterGoalMl, p.waterGoalMl);

      expect(
        find.text('Target ${Fmt.integer(p.calorieTarget)}'),
        findsOneWidget,
      ); // "Target 2,250"
      expect(
        find.text('Target ${p.proteinTargetG.round()} g'),
        findsOneWidget,
      ); // "Target 170 g"
      expect(
        find.text('Target ${Fmt.ml(p.waterGoalMl)}'),
        findsOneWidget,
      ); // "Target 3.5 L"
      expect(find.text('Target 2,000'), findsNothing, reason: 'seed default');
      // Nothing logged yet: honest empty states, no invented intake.
      expect(find.text('NOT LOGGED'), findsNWidgets(3));

      await driftTeardown(tester);
    },
  );
}
