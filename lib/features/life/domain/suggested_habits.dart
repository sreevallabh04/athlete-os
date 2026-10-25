import 'auto_rules.dart';
import 'habit_models.dart';

/// A habit the user may add from the "suggested habits" sheet. Nothing is
/// pre-selected; the user picks what fits.
class HabitTemplate {
  const HabitTemplate({
    required this.name,
    required this.category,
    this.schedule = const HabitSchedule.daily(),
    this.autoRule,
    this.reminderTimes = const [],
    this.note,
  });

  final String name;
  final HabitCategory category;
  final HabitSchedule schedule;
  final AutoRule? autoRule;
  final List<int> reminderTimes;
  final String? note;
}

const suggestedHabits = <HabitTemplate>[
  HabitTemplate(
    name: 'Drink water',
    category: HabitCategory.health,
    autoRule: AutoRule.waterGoal,
    note: 'Completes automatically when you reach your water goal.',
  ),
  HabitTemplate(
    name: 'Train',
    category: HabitCategory.fitness,
    schedule: HabitSchedule.weekly(4),
  ),
  HabitTemplate(
    name: 'Log meals',
    category: HabitCategory.nutrition,
    autoRule: AutoRule.foodLogged,
    note: 'Completes automatically once food is logged.',
  ),
  HabitTemplate(
    name: 'Reach step target',
    category: HabitCategory.fitness,
    autoRule: AutoRule.stepGoal,
    note: 'Completes automatically from synced step data.',
  ),
  HabitTemplate(name: 'Read', category: HabitCategory.mind),
  HabitTemplate(name: 'Journal', category: HabitCategory.mind),
  HabitTemplate(name: 'Sleep on time', category: HabitCategory.health),
  HabitTemplate(
    name: 'Prepare meals',
    category: HabitCategory.nutrition,
    schedule: HabitSchedule.weekly(2),
  ),
  HabitTemplate(
    name: 'Review tomorrow\'s priorities',
    category: HabitCategory.productivity,
  ),
  HabitTemplate(name: 'Take a break', category: HabitCategory.mind),
];
