import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../application/persona_providers.dart';
import '../domain/meal_ideas.dart';

/// "What can I eat?" card for the Nutrition screen. Opens a sheet with
/// deterministic, macro-tagged eggetarian suggestions for what's left today.
class MealIdeasCard extends StatelessWidget {
  const MealIdeasCard({
    super.key,
    required this.kcalLeft,
    required this.proteinLeft,
  });

  final double kcalLeft;
  final double proteinLeft;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      accent: AppColors.protein,
      onTap: () => showMealIdeasSheet(
        context,
        kcalLeft: kcalLeft,
        proteinLeft: proteinLeft,
      ),
      semanticLabel: 'What can I eat? Meal ideas for what is left today',
      child: Row(
        children: [
          const Icon(Icons.lightbulb_outline, color: AppColors.protein),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What can I eat?', style: t.titleSmall),
                Text(
                  kcalLeft <= 0
                      ? 'You\'re at today\'s calorie target.'
                      : '${kcalLeft.round()} kcal · '
                            '${proteinLeft.clamp(0, 999).round()} g protein '
                            'left',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

Future<void> showMealIdeasSheet(
  BuildContext context, {
  required double kcalLeft,
  required double proteinLeft,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => MealIdeasSheet(kcalLeft: kcalLeft, proteinLeft: proteinLeft),
);

class MealIdeasSheet extends ConsumerWidget {
  const MealIdeasSheet({
    super.key,
    required this.kcalLeft,
    required this.proteinLeft,
  });

  final double kcalLeft;
  final double proteinLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final a = ref.watch(calibrationProvider).value;
    final library = mealsForDiet(
      a?.dietType ?? 'eggetarian',
      dislikes: a?.dislikes ?? const [],
    );
    final ideas = mealIdeasForRemaining(
      kcalLeft,
      proteinLeft,
      library: library,
    );
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.xxl,
        ),
        children: [
          Text('What can I eat?', style: t.titleLarge),
          Text(
            '${kcalLeft.round()} kcal and '
            '${proteinLeft.clamp(0, 999).round()} g protein left. Ranked by '
            'protein per calorie.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          if (ideas.isEmpty)
            const EmptyState(
              compact: true,
              icon: Icons.check_circle_outline,
              title: 'Nothing fits what\'s left',
              message:
                  'You\'re close to today\'s target. Water, black coffee '
                  'or a cucumber salad if hungry.',
            ),
          for (var i = 0; i < ideas.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: 260 + 60 * i),
                curve: Curves.easeOutCubic,
                builder: (context, v, child) => Opacity(
                  opacity: v,
                  child: Transform.translate(
                    offset: Offset(0, (1 - v) * 14),
                    child: child,
                  ),
                ),
                child: _IdeaTile(idea: ideas[i]),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Macros are estimates from generic USDA / IFCT values per 100 g; '
            'brands and recipes vary.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _IdeaTile extends StatelessWidget {
  const _IdeaTile({required this.idea});
  final MealIdea idea;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(idea.name, style: t.titleSmall)),
              Text('${idea.kcal} kcal', style: t.labelLarge),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              _Tag('${idea.proteinG} g P', AppColors.protein),
              _Tag('${idea.carbsG} g C', AppColors.carbs),
              _Tag('${idea.fatG} g F', AppColors.fat),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            idea.ingredientSummary,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: AppRadii.chip,
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}
