/// Automatic habit completion rules evaluated from logged data. Pure Dart.
library;

enum AutoRule {
  waterGoal(
    'water_goal',
    'Water goal reached',
    'Auto-completes when today\'s '
        'logged water reaches your daily water goal.',
  ),
  stepGoal(
    'step_goal',
    'Step goal reached',
    'Auto-completes when synced or '
        'entered steps reach your daily step goal.',
  ),
  foodLogged(
    'food_logged',
    'Food logged',
    'Auto-completes when at least one '
        'food entry is logged that day.',
  );

  const AutoRule(this.key, this.label, this.description);
  final String key;
  final String label;
  final String description;

  static AutoRule? fromKey(String? key) {
    for (final r in values) {
      if (r.key == key) return r;
    }
    return null;
  }
}

/// Data needed to evaluate auto rules for one local date.
class AutoRuleDay {
  const AutoRuleDay({
    this.waterMl = 0,
    this.waterGoalMl = 0,
    this.steps,
    this.stepGoal = 0,
    this.foodEntries = 0,
  });

  final int waterMl;
  final int waterGoalMl;

  /// Null when no step data exists for the day (unknown, not zero).
  final double? steps;
  final int stepGoal;
  final int foodEntries;
}

/// Whether [rule] is satisfied by [day]. Missing data is never treated as
/// success, and a non-positive goal never auto-completes.
bool autoRuleMet(AutoRule rule, AutoRuleDay day) => switch (rule) {
  AutoRule.waterGoal => day.waterGoalMl > 0 && day.waterMl >= day.waterGoalMl,
  AutoRule.stepGoal =>
    day.stepGoal > 0 && day.steps != null && day.steps! >= day.stepGoal,
  AutoRule.foodLogged => day.foodEntries > 0,
};
