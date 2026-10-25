/// Pure profile editing rules: diff detection and calorie-change caution.
library;

import 'package:collection/collection.dart';

/// Editable copy of the user profile, independent of Drift.
class ProfileDraft {
  const ProfileDraft({
    this.displayName,
    this.heightCm,
    this.targetWeightKg,
    this.dietType = 'eggetarian',
    this.restrictions = const [],
    this.dislikedFoods = const [],
    this.calorieTarget = 2000,
    this.proteinTargetG = 150,
    this.carbsTargetG = 200,
    this.fatTargetG = 60,
    this.fiberTargetG,
    this.stepGoal = 10000,
    this.waterGoalMl = 3000,
    this.wakeMinutes = 390,
    this.sleepMinutes = 1350,
    this.coachingStyle = 'direct',
    this.trainingAvailability,
    this.runGoalDistanceM = 5000,
    this.runGoalTimeS = 1800,
    this.fitnessGoals,
  });

  final String? displayName;
  final double? heightCm;
  final double? targetWeightKg;
  final String dietType;
  final List<String> restrictions;
  final List<String> dislikedFoods;
  final int calorieTarget;
  final double proteinTargetG;
  final double carbsTargetG;
  final double fatTargetG;
  final double? fiberTargetG;
  final int stepGoal;
  final int waterGoalMl;
  final int wakeMinutes;
  final int sleepMinutes;
  final String coachingStyle;
  final String? trainingAvailability;
  final int runGoalDistanceM;
  final int runGoalTimeS;
  final String? fitnessGoals;

  /// Field key → (label, value, isTarget). Keys match the Drift JSON keys so
  /// goal-history entries line up with what the user saw.
  Map<String, ({String label, Object? value, bool isTarget})> get fields => {
    'displayName': (
      label: 'Display name',
      value: _n(displayName),
      isTarget: false,
    ),
    'heightCm': (label: 'Height (cm)', value: heightCm, isTarget: false),
    'targetWeightKg': (
      label: 'Target weight (kg)',
      value: targetWeightKg,
      isTarget: true,
    ),
    'dietType': (label: 'Diet type', value: dietType, isTarget: false),
    'restrictions': (
      label: 'Dietary restrictions',
      value: restrictions.join(', '),
      isTarget: false,
    ),
    'dislikedFoods': (
      label: 'Disliked foods',
      value: dislikedFoods.join(', '),
      isTarget: false,
    ),
    'calorieTarget': (
      label: 'Calorie target (kcal)',
      value: calorieTarget,
      isTarget: true,
    ),
    'proteinTargetG': (
      label: 'Protein target (g)',
      value: proteinTargetG,
      isTarget: true,
    ),
    'carbsTargetG': (
      label: 'Carb target (g)',
      value: carbsTargetG,
      isTarget: true,
    ),
    'fatTargetG': (label: 'Fat target (g)', value: fatTargetG, isTarget: true),
    'fiberTargetG': (
      label: 'Fiber target (g)',
      value: fiberTargetG,
      isTarget: true,
    ),
    'stepGoal': (label: 'Step goal', value: stepGoal, isTarget: true),
    'waterGoalMl': (
      label: 'Water goal (ml)',
      value: waterGoalMl,
      isTarget: true,
    ),
    'wakeMinutes': (
      label: 'Wake time',
      value: formatMinutes(wakeMinutes),
      isTarget: false,
    ),
    'sleepMinutes': (
      label: 'Sleep time',
      value: formatMinutes(sleepMinutes),
      isTarget: false,
    ),
    'coachingStyle': (
      label: 'Coaching style',
      value: coachingStyle,
      isTarget: false,
    ),
    'trainingAvailability': (
      label: 'Training availability',
      value: _n(trainingAvailability),
      isTarget: false,
    ),
    'runGoalDistanceM': (
      label: 'Run goal distance (m)',
      value: runGoalDistanceM,
      isTarget: true,
    ),
    'runGoalTimeS': (
      label: 'Run goal time',
      value: formatSeconds(runGoalTimeS),
      isTarget: true,
    ),
    'fitnessGoals': (
      label: 'Fitness goals',
      value: _n(fitnessGoals),
      isTarget: false,
    ),
  };

  static String? _n(String? s) => (s == null || s.trim().isEmpty) ? null : s;
}

class FieldChange {
  const FieldChange({
    required this.key,
    required this.label,
    required this.oldValue,
    required this.newValue,
    required this.isTarget,
  });

  final String key;
  final String label;
  final Object? oldValue;
  final Object? newValue;
  final bool isTarget;

  String get oldText => _fmt(oldValue);
  String get newText => _fmt(newValue);

  static String _fmt(Object? v) {
    if (v == null) return '—';
    if (v is double) {
      return v == v.roundToDouble() ? v.round().toString() : v.toString();
    }
    final s = v.toString();
    return s.isEmpty ? '—' : s;
  }

  @override
  String toString() => '$label: $oldText → $newText';
}

/// Every field that differs between [before] and [after].
List<FieldChange> diffProfile(ProfileDraft before, ProfileDraft after) {
  final b = before.fields;
  final a = after.fields;
  final out = <FieldChange>[];
  for (final key in a.keys) {
    final ov = b[key]!.value;
    final nv = a[key]!.value;
    if (!_equal(ov, nv)) {
      out.add(
        FieldChange(
          key: key,
          label: a[key]!.label,
          oldValue: ov,
          newValue: nv,
          isTarget: a[key]!.isTarget,
        ),
      );
    }
  }
  return out;
}

bool _equal(Object? a, Object? b) {
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  if (a is List && b is List) return const ListEquality<Object?>().equals(a, b);
  final as = a is String && a.isEmpty ? null : a;
  final bs = b is String && b.isEmpty ? null : b;
  return as == bs;
}

enum CalorieCaution { none, belowFloor, largeDrop }

/// Cautions (never blocks) when a calorie target is set below 1500 kcal or is
/// reduced by more than 25% in one change.
CalorieCaution calorieCaution(int oldTarget, int newTarget) {
  if (newTarget < 1500) return CalorieCaution.belowFloor;
  if (oldTarget > 0 && (oldTarget - newTarget) / oldTarget > 0.25) {
    return CalorieCaution.largeDrop;
  }
  return CalorieCaution.none;
}

String calorieCautionMessage(CalorieCaution c) => switch (c) {
  CalorieCaution.belowFloor =>
    'This target is below 1,500 kcal. Very low intakes can affect health, '
        'training and recovery — please discuss it with a doctor or registered '
        'dietitian before relying on it.',
  CalorieCaution.largeDrop =>
    'This is a drop of more than 25% in one step. Large, sudden cuts are '
        'hard to sustain and can affect health — consider a gradual change and '
        'consult a qualified professional.',
  CalorieCaution.none => '',
};

/// 390 → "06:30".
String formatMinutes(int minutes) {
  final m = minutes % (24 * 60);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// 1800 → "30:00", 3725 → "1:02:05".
String formatSeconds(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Parses "30:00", "1:02:05" or "1800" into seconds. Null when invalid.
int? parseDuration(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final parts = s.split(':');
  if (parts.length > 3) return null;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n < 0)) return null;
  var total = 0;
  for (final n in nums) {
    total = total * 60 + n!;
  }
  return total;
}
