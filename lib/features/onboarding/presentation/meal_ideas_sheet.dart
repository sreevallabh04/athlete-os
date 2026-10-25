import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../application/persona_providers.dart';
import '../domain/meal_ideas.dart';

List<MealIdea> _ideasFor(WidgetRef ref, double kcalLeft, double proteinLeft) {
  final a = ref.watch(calibrationProvider).value;
  final library = mealsForDiet(
    a?.dietType ?? 'eggetarian',
    dislikes: a?.dislikes ?? const [],
  );
  return mealIdeasForRemaining(kcalLeft, proteinLeft, library: library);
}

/// "What can I eat?" card for the Nutrition screen: what's left today and
/// the top-ranked idea at a glance. Opens a sheet with deterministic,
/// macro-tagged eggetarian suggestions.
class MealIdeasCard extends ConsumerWidget {
  const MealIdeasCard({
    super.key,
    required this.kcalLeft,
    required this.proteinLeft,
  });

  final double kcalLeft;
  final double proteinLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final ideas = _ideasFor(ref, kcalLeft, proteinLeft);
    final top = ideas.isEmpty ? null : ideas.first;
    final p = proteinLeft.clamp(0, 999).round();
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
          SizedBox(
            width: 68,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                children: [
                  AnimatedTicker('$p', style: hud.number(size: 30)),
                  Text('G PROTEIN', style: hud.label(size: 9.5)),
                  Text('TO GO', style: hud.label(size: 9.5)),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 56,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            color: AppColors.protein.withValues(alpha: 0.3),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What can I eat?', style: t.titleSmall),
                const SizedBox(height: 2),
                Text(
                  kcalLeft <= 0
                      ? 'You\'re at today\'s calorie target.'
                      : top == null
                      ? '${kcalLeft.round()} kcal left today'
                      : 'Top pick: ${top.name} · ${top.proteinG} g P',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
  }
}

Future<void> showMealIdeasSheet(
  BuildContext context, {
  required double kcalLeft,
  required double proteinLeft,
}) => showHudBottomSheet<void>(
  context,
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
    final hud = context.hud;
    final ideas = _ideasFor(ref, kcalLeft, proteinLeft);
    final maxH = MediaQuery.sizeOf(context).height * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        children: [
          Text('What can I eat?', style: t.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${kcalLeft.round()} kcal and '
            '${proteinLeft.clamp(0, 999).round()} g protein left. Ranked by '
            'protein per calorie.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: _Budget(
                  label: 'KCAL LEFT',
                  value: math.max(0, kcalLeft).round(),
                  color: AppColors.calories,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Budget(
                  label: 'PROTEIN LEFT',
                  value: proteinLeft.clamp(0, 999).round(),
                  suffix: ' g',
                  color: AppColors.protein,
                ),
              ),
            ],
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
          ...staggered([
            for (var i = 0; i < ideas.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _IdeaTile(
                  idea: ideas[i],
                  rank: i + 1,
                  proteinLeft: proteinLeft,
                ),
              ),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Macros are estimates from generic USDA / IFCT values per 100 g; '
            'brands and recipes vary.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Budget extends StatelessWidget {
  const _Budget({
    required this.label,
    required this.value,
    required this.color,
    this.suffix = '',
  });

  final String label;
  final int value;
  final Color color;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return GlassPanel(
      accent: color,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      radius: AppRadii.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: hud.label(size: 10.5)),
          AnimatedTicker.value(
            value,
            suffix: suffix,
            style: hud.number(size: 26),
          ),
        ],
      ),
    );
  }
}

class _IdeaTile extends StatelessWidget {
  const _IdeaTile({
    required this.idea,
    required this.rank,
    required this.proteinLeft,
  });
  final MealIdea idea;
  final int rank;
  final double proteinLeft;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final share = proteinLeft <= 0
        ? 1.0
        : (idea.proteinG / proteinLeft).clamp(0.0, 1.0);
    final efficiency = idea.kcal <= 0 ? 0 : idea.proteinG / idea.kcal * 100;
    return GlassPanel(
      accent: rank == 1 ? AppColors.protein : null,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '#$rank',
                style: hud.mono(
                  size: 11,
                  color: rank == 1 ? hud.accentInk : hud.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(idea.name, style: t.titleSmall)),
              const SizedBox(width: AppSpacing.sm),
              Text('${idea.kcal} kcal', style: t.labelLarge),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _Tag('${idea.proteinG} g P', AppColors.protein),
              _Tag('${idea.carbsG} g C', AppColors.carbs),
              _Tag('${idea.fatG} g F', AppColors.fat),
              _Tag(
                '${efficiency.toStringAsFixed(1)} g P / 100 kcal',
                hud.textMuted,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            idea.ingredientSummary,
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 3,
                    color: AppColors.protein,
                    backgroundColor: AppColors.protein.withValues(alpha: 0.12),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                proteinLeft <= 0
                    ? 'TARGET MET'
                    : 'COVERS ${(share * 100).round()}%',
                style: hud.label(size: 9.5),
              ),
            ],
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
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: hud.isDark ? color : hud.text),
      ),
    );
  }
}
