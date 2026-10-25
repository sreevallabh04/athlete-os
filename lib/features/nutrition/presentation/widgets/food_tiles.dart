import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../data/mappers.dart';
import '../../domain/food_models.dart';
import 'common.dart';
import 'nutrition_hud.dart';

/// Glass result card shared by local foods and database candidates.
class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.name,
    required this.meta,
    required this.kcal,
    required this.kcalUnit,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.onTap,
    this.onLongPress,
    this.badges = const [],
    this.trailing,
    this.warning,
    this.semanticLabel,
  });

  final String name;
  final String meta;
  final double? kcal;
  final String kcalUnit;
  final double? protein;
  final double? carbs;
  final double? fat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final List<Widget> badges;
  final Widget? trailing;
  final String? warning;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        onTap: onTap,
        onLongPress: onLongPress,
        semanticLabel: semanticLabel,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.calories.withValues(alpha: 0.22),
                    AppColors.calories.withValues(alpha: 0.04),
                  ],
                ),
                border: Border.all(
                  color: AppColors.calories.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                initial,
                style: hud.number(size: 18, color: hud.text),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: t.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (badges.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: badges,
                    ),
                  ],
                  if (warning != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      warning!,
                      style: t.labelSmall?.copyWith(color: AppColors.warning),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: 0.7,
                    child: MacroSplitBar(
                      protein: protein ?? 0,
                      carbs: carbs ?? 0,
                      fat: fat ?? 0,
                      height: 3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  kcal == null ? '—' : Fmt.integer(kcal!),
                  style: hud.number(size: 22),
                ),
                Text(kcalUnit, style: hud.label(size: 9.5)),
                if (protein != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'P ${Fmt.grams(protein!)}',
                    style: t.labelSmall?.copyWith(
                      color: hud.isDark ? AppColors.protein : hud.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Result card for a local food.
class FoodListTile extends StatelessWidget {
  const FoodListTile({
    super.key,
    required this.food,
    required this.onTap,
    this.onToggleFavorite,
    this.onLongPress,
  });

  final Food food;
  final VoidCallback onTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final b = food.basis;
    final estimate = Verifications.isEstimate(food.verification);
    return _FoodCard(
      name: food.name,
      meta: [?food.brand, b.servingLabel].join(' · '),
      kcal: food.calories,
      kcalUnit: 'KCAL / SERVING',
      protein: food.proteinG,
      carbs: food.carbsG,
      fat: food.fatG,
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel:
          '${food.name}, ${Fmt.kcal(food.calories)} per ${b.servingLabel}, '
          'protein ${Fmt.grams(food.proteinG)}',
      badges: [
        if (estimate)
          const EstimateBadge()
        else
          VerificationLabel(food.verification),
      ],
      trailing: onToggleFavorite == null
          ? null
          : IconButton(
              tooltip: food.isFavorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              icon: Icon(
                food.isFavorite ? Icons.star_rounded : Icons.star_outline,
                color: food.isFavorite ? AppColors.gold : null,
                shadows: food.isFavorite
                    ? AppGlows.text(
                        AppColors.gold,
                        strength: context.hud.glowStrength,
                      )
                    : null,
              ),
              onPressed: () {
                Haptics.selection();
                onToggleFavorite!();
              },
            ),
    );
  }
}

/// Result card for a remote database result (not yet saved locally).
class CandidateTile extends StatelessWidget {
  const CandidateTile({
    super.key,
    required this.candidate,
    required this.onTap,
  });
  final FoodCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    final per100 = c.kcal100g != null;
    return _FoodCard(
      name: c.name,
      meta: [
        ?c.brand,
        per100 ? 'per 100 ${c.servingUnit}' : 'per serving',
      ].join(' · '),
      kcal: per100 ? c.kcal100g : c.kcalServing,
      kcalUnit: per100 ? 'KCAL / 100 ${c.servingUnit.toUpperCase()}' : 'KCAL',
      protein: per100 ? c.protein100g : c.proteinServing,
      carbs: per100 ? c.carbs100g : c.carbsServing,
      fat: per100 ? c.fat100g : c.fatServing,
      onTap: onTap,
      semanticLabel: '${c.name}${c.brand != null ? ', ${c.brand}' : ''}',
      warning: c.isComplete
          ? null
          : 'Incomplete: missing ${c.missingNutrients.join(', ')}',
      badges: [
        Text(
          FoodSources.label(c.source).toUpperCase(),
          style: context.hud.mono(size: 9.5),
        ),
      ],
      trailing: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Icon(
          c.isComplete ? Icons.add_circle_outline : Icons.edit_note,
          color: context.hud.accentInk,
          semanticLabel: c.isComplete ? 'Add' : 'Complete manually',
        ),
      ),
    );
  }
}
