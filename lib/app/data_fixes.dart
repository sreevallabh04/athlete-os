import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/redact.dart';
import '../data/db/database.dart';
import '../data/repositories/profile_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../features/onboarding/domain/calibration.dart';
import '../features/onboarding/domain/nutrition_calculator.dart';

/// One-shot, user-requested data changes for an existing install.
///
/// Each fix runs at most once (flag in AppSettings), goes through
/// [ProfileRepository.update] so the change is recorded in goal history with
/// the reason, and never runs on a fresh install (onboarding not done) —
/// new installs get the same values from the calibration defaults.
abstract final class DataFixKeys {
  static const kcal2000 = 'data_fix.kcal_2000_v1';
}

/// 2026-10-26: Sreevallabh asked for a 2,000 kcal target (calibration had
/// produced 2,100 at 0.75 %/week). 2,000 kcal = 0.9 % BW/week with protein
/// 170 g and fat 65 g kept; carbs absorb the difference.
Future<void> applyKcal2000Fix({
  required SettingsRepository settings,
  required ProfileRepository profiles,
}) async {
  if ((await settings.get<bool>(DataFixKeys.kcal2000)) == true) return;
  if ((await settings.get<bool>(SettingKeys.onboardingDone)) != true) return;

  final raw = await settings.get<Object?>(PersonaKeys.calibration);
  final answers = CalibrationAnswers.fromJson(raw).copyWith(weeklyRatePct: 0.9);
  final plan = calculateNutrition(answers.nutritionInputs);

  final profile = await profiles.get();
  if (profile.calorieTarget != plan.targetKcal ||
      profile.carbsTargetG.round() != plan.carbsG) {
    await profiles.update(
      UserProfilesCompanion(
        calorieTarget: Value(plan.targetKcal),
        proteinTargetG: Value(plan.proteinG.toDouble()),
        fatTargetG: Value(plan.fatG.toDouble()),
        carbsTargetG: Value(plan.carbsG.toDouble()),
      ),
      changedBy: 'user',
      reason:
          'Requested by Sreevallabh (2026-10-26): 2,000 kcal target '
          '(0.9 % body weight per week).',
    );
  }
  // Keep the saved calibration consistent so the weekly check-in and a
  // future recalibration use the same rate.
  await settings.set(PersonaKeys.calibration, answers.toJson());
  await settings.set(DataFixKeys.kcal2000, true);
}

Future<void> dataFixesBootstrap(ProviderContainer container) async {
  try {
    await applyKcal2000Fix(
      settings: container.read(settingsRepositoryProvider),
      profiles: container.read(profileRepositoryProvider),
    );
  } catch (e) {
    debugPrint('data fix kcal_2000 failed: ${redactSecrets(e.toString())}');
  }
}
