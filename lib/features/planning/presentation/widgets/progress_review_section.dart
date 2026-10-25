import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/paths.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/planning_providers.dart';
import '../../domain/metrics.dart';
import 'charts.dart';
import 'ui_helpers.dart';

/// Weekly progress review for competition prep. Every block is computed from
/// stored data and states clearly when data is missing.
class ProgressReviewSection extends ConsumerWidget {
  const ProgressReviewSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(progressReviewProvider);
    return data.when(
      loading: () => const LoadingState(),
      error: (e, _) =>
          const ErrorState(message: 'Could not load progress data.'),
      data: (d) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: spaced([
          _WeightCard(d: d),
          _NutritionAdherenceCard(d: d),
          _TrainingCard(d: d),
          _CardioCard(d: d),
          AppCard(
            onTap: () => context.push(AppPaths.notificationSettings),
            child: const CardTitle(
              icon: Icons.accessibility_new,
              title: 'Posing practice reminders',
              color: AppColors.gold,
              trailing: Icon(Icons.chevron_right),
            ),
          ),
        ]),
      ),
    );
  }
}

class _WeightCard extends StatelessWidget {
  const _WeightCard({required this.d});
  final ProgressReviewData d;

  @override
  Widget build(BuildContext context) {
    final last28 = LocalDates.addDays(d.today, -27);
    final recent = d.weights
        .where((w) => w.date.compareTo(last28) >= 0)
        .toList();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(
            icon: Icons.monitor_weight_outlined,
            title: 'Body-weight trend (28 days)',
            color: AppColors.brandAlt,
          ),
          const SizedBox(height: AppSpacing.md),
          if (recent.isEmpty)
            EmptyState(
              compact: true,
              icon: Icons.monitor_weight_outlined,
              title: 'No weight entries yet',
              message: 'Add weigh-ins manually or sync a smart scale.',
              actionLabel: 'Add weight',
              onAction: () => context.push(AppPaths.healthOverview),
            )
          else ...[
            Builder(
              builder: (context) {
                final ma = trailingMovingAverage(recent);
                final raw = dailyMeans(recent);
                final first = ma.first.value;
                final last = ma.last.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: AppSpacing.xl,
                      runSpacing: AppSpacing.sm,
                      children: [
                        StatTile(
                          label: '7-day average',
                          value: '${last.toStringAsFixed(1)} kg',
                        ),
                        if (ma.length > 1)
                          StatTile(
                            label: 'Change in average',
                            value:
                                '${last - first >= 0 ? '+' : ''}'
                                '${(last - first).toStringAsFixed(1)} kg',
                            sub: 'over ${raw.length} weigh-in days',
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    DateLineChart(
                      unit: 'kg',
                      lines: [
                        DateLine(
                          points: raw,
                          color: AppColors.brandAlt.withValues(alpha: 0.6),
                          label: 'Daily weigh-in',
                          dotsOnly: true,
                        ),
                        DateLine(
                          points: ma,
                          color: AppColors.brandAlt,
                          label: '7-day average',
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ChartLegend(
                      items: [
                        (
                          AppColors.brandAlt.withValues(alpha: 0.6),
                          'Daily weigh-in',
                        ),
                        (AppColors.brandAlt, '7-day average'),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Hint(
                      'Source: ${sourcesLabel(recent.map((w) => w.origin))}',
                    ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const NoticeBanner(
            icon: Icons.info_outline,
            message:
                'Day-to-day scale changes mostly reflect water, food volume '
                'and glycogen — they are not fat or muscle changes. Judge '
                'progress on the multi-week average, photos and performance.',
          ),
        ],
      ),
    );
  }
}

class _NutritionAdherenceCard extends StatelessWidget {
  const _NutritionAdherenceCard({required this.d});
  final ProgressReviewData d;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    NutritionAdherence a(int days) => nutritionAdherence(
      d.nutrition,
      LocalDates.range(LocalDates.addDays(d.today, -(days - 1)), d.today),
      calorieTarget: d.calorieTarget,
      proteinTargetG: d.proteinTargetG,
    );
    final w = a(7);
    final m = a(28);
    Widget column(String title, NutritionAdherence x) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          if (x.loggedDays == 0)
            const Hint('No food logged')
          else ...[
            Text(
              '${x.loggedDays}/${x.totalDays} days logged',
              style: t.bodySmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            MetricBar(
              label: 'Protein ≥ target',
              value: x.proteinDays.toDouble(),
              target: x.loggedDays.toDouble(),
              color: AppColors.protein,
              unit: ' d',
            ),
            const SizedBox(height: AppSpacing.xs),
            MetricBar(
              label: 'Calories ±10%',
              value: x.calorieDays.toDouble(),
              target: x.loggedDays.toDouble(),
              color: AppColors.calories,
              unit: ' d',
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('Both on ${x.bothDays} days', style: t.bodySmall),
          ],
        ],
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(
            icon: Icons.restaurant_menu,
            title: 'Nutrition adherence',
            color: AppColors.protein,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              column('Last 7 days', w),
              const SizedBox(width: AppSpacing.lg),
              column('Last 28 days', m),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Hint(
            'Targets: ${Fmt.grams(d.proteinTargetG.round())} protein, '
            '${Fmt.kcal(d.calorieTarget)}. Only logged days can count; '
            'unlogged days are not assumed.',
          ),
        ],
      ),
    );
  }
}

class _TrainingCard extends StatelessWidget {
  const _TrainingCard({required this.d});
  final ProgressReviewData d;

  @override
  Widget build(BuildContext context) {
    final weeks = weekStarts(d.today, 8);
    final totals = weeklyTotals(
      d.workouts,
      date: (w) => w.date,
      value: (_) => 1,
      weeks: weeks,
    );
    final total = totals.values.fold(0.0, (a, b) => a + b);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(
            icon: Icons.fitness_center,
            title: 'Training consistency (8 weeks)',
            color: AppColors.strength,
          ),
          const SizedBox(height: AppSpacing.md),
          if (total == 0)
            const Hint('No workouts recorded in the last 8 weeks.')
          else ...[
            LabeledBarChart(
              labels: [for (final w in weeks) formatDateKey(w, pattern: 'd/M')],
              values: [for (final w in weeks) totals[w]!],
              color: AppColors.strength,
              unit: 'workouts',
              valueFormat: (v) => v.round().toString(),
            ),
            const SizedBox(height: AppSpacing.xs),
            Hint(
              'Workouts per Monday-start week · average '
              '${(total / 8).toStringAsFixed(1)}/week · '
              'source: ${sourcesLabel(d.workouts.map((w) => w.source))}',
            ),
          ],
        ],
      ),
    );
  }
}

class _CardioCard extends StatelessWidget {
  const _CardioCard({required this.d});
  final ProgressReviewData d;

  @override
  Widget build(BuildContext context) {
    final weeks = weekStarts(d.today, 8);
    final runs = d.cardio.where((c) => c.isRun).toList();
    final totals = weeklyTotals(
      runs,
      date: (r) => r.date,
      value: (r) => (r.distanceM ?? 0) / 1000,
      weeks: weeks,
    );
    final total = totals.values.fold(0.0, (a, b) => a + b);
    final others = d.cardio.length - runs.length;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(
            icon: Icons.directions_run,
            title: 'Running volume (8 weeks)',
            color: AppColors.running,
          ),
          const SizedBox(height: AppSpacing.md),
          if (total == 0)
            const Hint('No runs with distance recorded in the last 8 weeks.')
          else ...[
            LabeledBarChart(
              labels: [for (final w in weeks) formatDateKey(w, pattern: 'd/M')],
              values: [for (final w in weeks) totals[w]!],
              color: AppColors.running,
              unit: 'km',
            ),
            const SizedBox(height: AppSpacing.xs),
            Hint(
              'Weekly running km · sources: '
              '${sourcesLabel(runs.map((r) => r.source))}'
              '${others > 0 ? ' · $others walks/rides/other excluded' : ''}',
            ),
          ],
        ],
      ),
    );
  }
}
