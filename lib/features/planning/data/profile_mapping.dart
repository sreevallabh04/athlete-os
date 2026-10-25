import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../data/db/database.dart';
import '../domain/profile_diff.dart';

List<String> _list(String json) {
  try {
    return (jsonDecode(json) as List).map((e) => e.toString()).toList();
  } catch (_) {
    return const [];
  }
}

ProfileDraft draftFromProfile(UserProfile p) => ProfileDraft(
  displayName: p.displayName,
  heightCm: p.heightCm,
  targetWeightKg: p.targetWeightKg,
  dietType: p.dietType,
  restrictions: _list(p.restrictionsJson),
  dislikedFoods: _list(p.dislikedFoodsJson),
  calorieTarget: p.calorieTarget,
  proteinTargetG: p.proteinTargetG,
  carbsTargetG: p.carbsTargetG,
  fatTargetG: p.fatTargetG,
  fiberTargetG: p.fiberTargetG,
  stepGoal: p.stepGoal,
  waterGoalMl: p.waterGoalMl,
  wakeMinutes: p.wakeMinutes,
  sleepMinutes: p.sleepMinutes,
  coachingStyle: p.coachingStyle,
  trainingAvailability: p.trainingAvailability,
  runGoalDistanceM: p.runGoalDistanceM,
  runGoalTimeS: p.runGoalTimeS,
  fitnessGoals: p.fitnessGoals,
);

String? _blank(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

UserProfilesCompanion companionFromDraft(ProfileDraft d) =>
    UserProfilesCompanion(
      displayName: Value(_blank(d.displayName)),
      heightCm: Value(d.heightCm),
      targetWeightKg: Value(d.targetWeightKg),
      dietType: Value(d.dietType),
      restrictionsJson: Value(jsonEncode(d.restrictions)),
      dislikedFoodsJson: Value(jsonEncode(d.dislikedFoods)),
      calorieTarget: Value(d.calorieTarget),
      proteinTargetG: Value(d.proteinTargetG),
      carbsTargetG: Value(d.carbsTargetG),
      fatTargetG: Value(d.fatTargetG),
      fiberTargetG: Value(d.fiberTargetG),
      stepGoal: Value(d.stepGoal),
      waterGoalMl: Value(d.waterGoalMl),
      wakeMinutes: Value(d.wakeMinutes),
      sleepMinutes: Value(d.sleepMinutes),
      coachingStyle: Value(d.coachingStyle),
      trainingAvailability: Value(_blank(d.trainingAvailability)),
      runGoalDistanceM: Value(d.runGoalDistanceM),
      runGoalTimeS: Value(d.runGoalTimeS),
      fitnessGoals: Value(_blank(d.fitnessGoals)),
    );
