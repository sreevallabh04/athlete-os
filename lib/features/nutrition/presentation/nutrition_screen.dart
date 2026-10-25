import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../onboarding/presentation/meal_ideas_sheet.dart';
import '../application/providers.dart';
import '../data/mappers.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';
import 'add_food_screen.dart' show copyFromPreviousDay;
import 'widgets/common.dart';
import 'widgets/edit_entry_sheet.dart';

/// Entries swiped away but not yet removed by the database stream. Keeps
/// [Dismissible] happy (it must leave the tree synchronously).
class _HiddenEntries extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void hide(String id) => state = {...state, id};
  void show(String id) => state = {...state}..remove(id);
}

final _hiddenEntriesProvider = NotifierProvider<_HiddenEntries, Set<String>>(
  _HiddenEntries.new,
);

/// Nutrition tab: daily calories/macros vs targets, meals, water summary.
class NutritionScreen extends ConsumerWidget {
  const NutritionScreen({super.key});

  void _openAdd(BuildContext context, {MealType? meal, required String date}) {
    final params = {'date': date, 'meal': ?meal?.key};
    context.push(
      Uri(path: AppPaths.addFood, queryParameters: params).toString(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = ref.watch(nutritionDateProvider);
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final entries = ref.watch(dayEntriesProvider(date));
    final targets = ref.watch(nutritionTargetsProvider);
    final hidden = ref.watch(_hiddenEntriesProvider);

    return AppPage(
      title: 'Nutrition',
      actions: [
        IconButton(
          tooltip: 'Nutrition history',
          icon: const Icon(Icons.insights_outlined),
          onPressed: () => context.push(AppPaths.nutritionHistory),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'nutrition-add',
        onPressed: () => _openAdd(context, date: date),
        icon: const Icon(Icons.add),
        label: const Text('Log food'),
      ),
      children: [
        DateSwitcher(
          date: date,
          today: today,
          onChanged: ref.read(nutritionDateProvider.notifier).set,
        ),
        const SizedBox(height: AppSpacing.sm),
        ...entries.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [
            ErrorState(
              message: redactSecrets('$e'),
              onRetry: () => ref.invalidate(dayEntriesProvider(date)),
            ),
          ],
          data: (all) {
            final list = all.where((e) => !hidden.contains(e.id)).toList();
            final totals = DayTotals.fromLines(list.map((e) => e.line));
            return targets.when(
              loading: () => [const LoadingState()],
              error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
              data: (t) => [
                _SummaryCard(totals: totals, targets: t),
                if (date == today) ...[
                  const SizedBox(height: AppSpacing.md),
                  MealIdeasCard(
                    kcalLeft: t.calories - totals.total.calories,
                    proteinLeft: t.protein - totals.total.protein,
                  ),
                ],
                if (totals.estimateCount > 0) ...[
                  const SizedBox(height: AppSpacing.md),
                  NoticeBanner(
                    icon: Icons.auto_awesome_outlined,
                    color: AppColors.warning,
                    message:
                        'Includes ${totals.estimateCount} estimated '
                        'item${totals.estimateCount == 1 ? '' : 's'}. '
                        'Totals are approximate.',
                  ),
                ],
                if (totals.isEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  AppCard(
                    child: EmptyState(
                      icon: Icons.restaurant_outlined,
                      title: date == today
                          ? 'Nothing logged yet today'
                          : 'Nothing logged on this day',
                      message:
                          'Search, scan a barcode, describe your meal or '
                          'copy from yesterday.',
                      actionLabel: 'Log food',
                      onAction: () => _openAdd(context, date: date),
                    ),
                  ),
                ],
                for (final m in MealType.values)
                  _MealSection(
                    meal: m,
                    date: date,
                    entries: list.where((e) => e.mealType == m.key).toList(),
                    total: totals.byMeal[m]!,
                    onAdd: () => _openAdd(context, meal: m, date: date),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        _WaterCard(date: date),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => context.push(AppPaths.nutritionHistory),
              icon: const Icon(Icons.bar_chart, size: 18),
              label: const Text('History & trends'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => context.push(AppPaths.profile),
              child: const Text('Edit targets'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.totals, required this.targets});
  final DayTotals totals;
  final NutritionTargets targets;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final consumed = totals.total;
    final rem = RemainingSummary.compute(consumed, targets);
    final kcal = rem.calories;
    final over = kcal.isOver;
    final split = MacroSplit.of(consumed);
    final (pp, cp, fp) = split.roundedPercents();
    final ringLabel = !kcal.hasTarget
        ? 'No calorie target set'
        : over
        ? 'Over by ${Fmt.kcal(kcal.overBy)}'
        : '${Fmt.kcal(kcal.value!)} remaining';

    return AppCard(
      accent: AppColors.calories,
      semanticLabel:
          '${Fmt.kcal(consumed.calories)} eaten. $ringLabel. '
          'Target ${Fmt.kcal(targets.calories)}.',
      child: Column(
        children: [
          Row(
            children: [
              ProgressRing(
                progress: kcal.visualProgress,
                color: over ? AppColors.danger : AppColors.calories,
                size: 148,
                stroke: 14,
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      kcal.hasTarget
                          ? Fmt.integer(over ? kcal.overBy : kcal.value!)
                          : Fmt.integer(consumed.calories),
                      style: t.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: over ? AppColors.danger : null,
                      ),
                    ),
                    Text(
                      !kcal.hasTarget
                          ? 'kcal eaten'
                          : over
                          ? 'kcal over'
                          : 'kcal left',
                      style: t.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatTile(
                      label: 'Eaten',
                      value: Fmt.kcal(consumed.calories),
                      icon: Icons.local_fire_department_outlined,
                      color: AppColors.calories,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    StatTile(
                      label: 'Target',
                      value: kcal.hasTarget
                          ? Fmt.kcal(targets.calories)
                          : 'Not set',
                      icon: Icons.flag_outlined,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          ...spaced([
            MetricBar(
              label: 'Protein',
              value: consumed.protein,
              target: targets.protein,
              color: AppColors.protein,
              unit: ' g',
            ),
            MetricBar(
              label: 'Carbs',
              value: consumed.carbs,
              target: targets.carbs,
              color: AppColors.carbs,
              unit: ' g',
            ),
            MetricBar(
              label: 'Fat',
              value: consumed.fat,
              target: targets.fat,
              color: AppColors.fat,
              unit: ' g',
            ),
            if (targets.fiber != null && targets.fiber! > 0)
              MetricBar(
                label: 'Fiber',
                value: consumed.fiber ?? 0,
                target: targets.fiber!,
                color: AppColors.fiber,
                unit: ' g',
              ),
          ]),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  split.isEmpty
                      ? 'Macro split appears once you log food'
                      : 'Energy split · P $pp% · C $cp% · F $fp%',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (rem.protein.isOver || rem.protein.hasTarget)
                Text(
                  rem.protein.isOver
                      ? 'Protein ✓ +${Fmt.grams(rem.protein.overBy)}'
                      : '${Fmt.grams(rem.protein.value!)} protein to go',
                  style: t.labelMedium?.copyWith(color: AppColors.protein),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MealSection extends ConsumerWidget {
  const _MealSection({
    required this.meal,
    required this.date,
    required this.entries,
    required this.total,
    required this.onAdd,
  });

  final MealType meal;
  final String date;
  final List<FoodLogEntry> entries;
  final Nutrients total;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.xl,
            bottom: AppSpacing.xs,
          ),
          child: Row(
            children: [
              Semantics(
                header: true,
                child: Text(meal.label, style: t.titleMedium),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (entries.isNotEmpty)
                Text(
                  '${Fmt.kcal(total.calories)} · '
                  'P ${Fmt.grams(total.protein)}',
                  style: t.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '${meal.label} options',
                onSelected: (v) {
                  if (v == 'copy') {
                    copyFromPreviousDay(context, ref, meal: meal, date: date);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(
                      'Copy ${meal.label.toLowerCase()} from yesterday',
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Add to ${meal.label}',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: onAdd,
              ),
            ],
          ),
        ),
        if (entries.isEmpty)
          Text(
            'Nothing logged',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: AppSpacing.lg),
                  _EntryTile(entry: entries[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _EntryTile extends ConsumerWidget {
  const _EntryTile({required this.entry});
  final FoodLogEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    final scheme = Theme.of(context).colorScheme;
    final estimate = Verifications.isEstimate(e.verification);
    return Dismissible(
      key: ValueKey('entry-${e.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.xl),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.85),
          borderRadius: AppRadii.card,
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) async {
        final log = ref.read(foodLogRepositoryProvider);
        final hidden = ref.read(_hiddenEntriesProvider.notifier);
        final messenger = ScaffoldMessenger.maybeOf(context);
        hidden.hide(e.id);
        await log.softDelete(e.id);
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Deleted ${e.name}'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  await log.restore(e.id);
                  hidden.show(e.id);
                },
              ),
            ),
          );
      },
      child: ListTile(
        minTileHeight: 60,
        onTap: () => showEditEntrySheet(context, e),
        title: Row(
          children: [
            Flexible(child: Text(e.name, overflow: TextOverflow.ellipsis)),
            if (estimate) ...[
              const SizedBox(width: AppSpacing.xs),
              const EstimateBadge(),
            ],
          ],
        ),
        subtitle: Text(
          [
            amountLabel(e.servings, e.grams),
            'P ${Fmt.grams(e.proteinG)}',
            if (e.brand != null) e.brand!,
          ].join(' · '),
          style: TextStyle(color: scheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          Fmt.kcal(e.calories),
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    );
  }
}

class _WaterCard extends ConsumerWidget {
  const _WaterCard({required this.date});
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(waterDayProvider(date));
    final profile = ref.watch(profileProvider);
    final t = Theme.of(context).textTheme;
    final goal = profile.value?.waterGoalMl ?? 0;
    final h = HydrationSummary.fromAmounts(
      (logs.value ?? const []).map((w) => w.amountMl),
      goal,
    );
    return AppCard(
      accent: AppColors.water,
      onTap: () => context.push(AppPaths.hydration),
      semanticLabel:
          'Water ${Fmt.ml(h.totalMl)} of ${Fmt.ml(goal)}. Open hydration.',
      child: Row(
        children: [
          ProgressRing(
            progress: h.visualProgress,
            color: AppColors.water,
            size: 56,
            stroke: 7,
            center: const Icon(
              Icons.water_drop,
              color: AppColors.water,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Water', style: t.titleMedium),
                Text(
                  logs.isLoading
                      ? 'Loading…'
                      : '${Fmt.ml(h.totalMl)} of ${Fmt.ml(goal)}'
                            '${h.goalReached ? ' · goal reached' : ''}',
                  style: t.bodyMedium,
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
