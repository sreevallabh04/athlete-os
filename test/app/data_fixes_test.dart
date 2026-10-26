import 'package:athlete_os/app/data_fixes.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/onboarding/domain/calibration.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late ProfileRepository profiles;

  setUp(() {
    db = newTestDb();
    settings = SettingsRepository(db);
    profiles = ProfileRepository(db);
  });
  tearDown(() => db.close());

  Future<void> calibratedAt2100() async {
    await settings.set(SettingKeys.onboardingDone, true);
    await settings.set(
      PersonaKeys.calibration,
      CalibrationAnswers.interviewDefaults()
          .copyWith(weeklyRatePct: 0.75)
          .toJson(),
    );
    await profiles.update(
      const UserProfilesCompanion(
        calorieTarget: Value(2100),
        carbsTargetG: Value(210),
      ),
    );
  }

  test('sets 2,000 kcal / 185 g carbs once, logged in goal history', () async {
    await calibratedAt2100();
    await applyKcal2000Fix(settings: settings, profiles: profiles);

    final p = await profiles.get();
    expect(p.calorieTarget, 2000);
    expect(p.carbsTargetG, 185);
    expect(p.proteinTargetG, 170);
    expect(p.fatTargetG, 65);

    final history = await profiles.history();
    final kcal = history.firstWhere(
      (h) => h.metric == 'calorieTarget' && h.newValue == '2000',
    );
    expect(kcal.oldValue, '2100');
    expect(kcal.newValue, '2000');
    expect(kcal.reason, contains('2,000 kcal'));

    final saved = CalibrationAnswers.fromJson(
      await settings.get<Object?>(PersonaKeys.calibration),
    );
    expect(saved.weeklyRatePct, 0.9);

    // Runs once: a later manual change is never overwritten.
    await profiles.update(
      const UserProfilesCompanion(calorieTarget: Value(2200)),
    );
    await applyKcal2000Fix(settings: settings, profiles: profiles);
    expect((await profiles.get()).calorieTarget, 2200);
  });

  test('does nothing on a fresh install (onboarding not done)', () async {
    await applyKcal2000Fix(settings: settings, profiles: profiles);
    expect((await profiles.get()).calorieTarget, 2000); // schema default
    expect(await profiles.history(), isEmpty);
    expect(await settings.get<bool>(DataFixKeys.kcal2000), isNull);
  });
}
