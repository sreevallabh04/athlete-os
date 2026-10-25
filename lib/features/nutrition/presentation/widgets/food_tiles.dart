import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../data/db/database.dart';
import '../../data/mappers.dart';
import '../../domain/food_models.dart';
import 'common.dart';

/// List tile for a local food.
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
    final scheme = Theme.of(context).colorScheme;
    final b = food.basis;
    final sub = [
      if (food.brand != null) food.brand!,
      '${b.servingLabel} · ${Fmt.kcal(food.calories)}',
      'P ${Fmt.grams(food.proteinG)}',
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      minTileHeight: 64,
      onTap: onTap,
      onLongPress: onLongPress,
      title: Row(
        children: [
          Flexible(child: Text(food.name, overflow: TextOverflow.ellipsis)),
          if (Verifications.isEstimate(food.verification)) ...[
            const SizedBox(width: AppSpacing.xs),
            const EstimateBadge(),
          ],
        ],
      ),
      subtitle: Text(
        '$sub\n${FoodSources.label(food.source)} · '
        '${Verifications.label(food.verification)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      isThreeLine: true,
      trailing: onToggleFavorite == null
          ? const Icon(Icons.add_circle_outline)
          : IconButton(
              tooltip: food.isFavorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              icon: Icon(
                food.isFavorite ? Icons.star_rounded : Icons.star_outline,
                color: food.isFavorite ? AppColors.fat : null,
              ),
              onPressed: onToggleFavorite,
            ),
    );
  }
}

/// List tile for a remote database result (not yet saved locally).
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
    final scheme = Theme.of(context).colorScheme;
    final c = candidate;
    final energy = c.kcal100g != null
        ? '${Fmt.kcal(c.kcal100g!)} / 100 ${c.servingUnit}'
        : c.kcalServing != null
        ? '${Fmt.kcal(c.kcalServing!)} / serving'
        : 'calories unknown';
    final protein = c.protein100g != null
        ? 'P ${Fmt.grams(c.protein100g!)}'
        : c.proteinServing != null
        ? 'P ${Fmt.grams(c.proteinServing!)}'
        : null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      minTileHeight: 64,
      onTap: onTap,
      title: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [?c.brand, energy, ?protein].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (!c.isComplete)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Incomplete: missing ${c.missingNutrients.join(', ')}',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: AppColors.warning),
              ),
            ),
        ],
      ),
      trailing: Icon(
        c.isComplete ? Icons.add_circle_outline : Icons.edit_note,
        semanticLabel: c.isComplete ? 'Add' : 'Complete manually',
      ),
    );
  }
}
