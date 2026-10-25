import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/config/env.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../application/train_providers.dart';
import '../domain/running_analytics.dart';
import '../domain/running_models.dart';
import 'widgets/charts.dart';
import 'widgets/strava_branding.dart';
import 'widgets/sync_status.dart';

class RunningScreen extends ConsumerWidget {
  const RunningScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cardioActivitiesProvider);
    final today = ref.watch(todayKeyProvider);
    final profile = ref.watch(profileProvider).value;
    final goalTime = profile?.runGoalTimeS ?? 1800;
    final goalDist = profile?.runGoalDistanceM ?? 5000;
    final strava = ref.watch(integrationStatusProvider(Providers.strava)).value;

    Future<void> refresh() async {
      if (Env.hasStrava && isConnected(strava)) {
        await ref.read(syncControllerProvider.notifier).syncStrava();
      }
    }

    return async.when(
      loading: () =>
          const AppPage(title: 'Running', children: [LoadingState()]),
      error: (e, _) => const AppPage(
        title: 'Running',
        children: [ErrorState(message: 'Could not load activities.')],
      ),
      data: (all) {
        final runs = all.where((a) => a.isRun).toList();
        if (all.isEmpty) {
          return AppPage(
            title: 'Running',
            onRefresh: refresh,
            children: [
              EmptyState(
                icon: Icons.directions_run,
                title: 'No runs yet',
                message:
                    'Connect Strava or allow exercise sessions in Health '
                    'Connect to see pace trends and 5K goal progress.',
                actionLabel: 'Connect apps',
                onAction: () => context.push(AppPaths.integrations),
              ),
            ],
          );
        }
        final weeks = weeklyRunning(all, todayKey: today, weeks: 8);
        final consistency = runConsistency(all, todayKey: today);
        final bests = runningBests(runs);
        final goal = goalProgress(
          bests.best5k,
          goalTimeS: goalTime,
          goalDistanceM: goalDist,
        );
        final pace = paceTrend(runs);
        final dist = distanceTrend(runs);
        final hasStrava = all.any((a) => a.isStrava);
        return AppPage(
          title: 'Running',
          onRefresh: refresh,
          children: [
            AppCard(
              accent: AppColors.running,
              child: Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: 'This week',
                      value:
                          '${(weeks.last.distanceM / 1000).toStringAsFixed(1)} km',
                      sub: '${weeks.last.runs} runs',
                      icon: Icons.directions_run,
                      color: AppColors.running,
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      label: 'Consistency',
                      value:
                          '${consistency.weeksWithRuns}/${consistency.weeks} wks',
                      sub: '${consistency.currentStreakWeeks}-week streak',
                    ),
                  ),
                ],
              ),
            ),
            const SectionHeader('5K goal'),
            _GoalCard(goal: goal, best: bests.best5k),
            const SectionHeader(
              'Weekly distance',
              subtitle: 'km, Monday weeks',
            ),
            AppCard(
              child: SimpleBarChart(
                values: [for (final w in weeks) w.distanceM / 1000],
                labels: [for (final w in weeks) weekLabel(w.weekStart)],
                color: AppColors.running,
                semanticLabel: 'Weekly running distance for 8 weeks',
                valueLabel: (v) => '${v.toStringAsFixed(1)} km',
              ),
            ),
            const SectionHeader(
              'Pace trend',
              subtitle: 'Average moving pace per run ≥ 1 km (lower is faster)',
            ),
            AppCard(
              child: pace.length < 2
                  ? const Text('Need at least two runs of 1 km or more.')
                  : TrendLineChart(
                      points: [
                        for (var i = 0; i < pace.length; i++)
                          (i.toDouble(), pace[i].value),
                      ],
                      color: AppColors.running,
                      semanticLabel:
                          'Pace trend. Latest ${Fmt.pace(pace.last.value)}',
                      yLabel: (v) => Fmt.pace(v).replaceAll(' /km', ''),
                      xLabel: (v) {
                        final i = v.round();
                        return i >= 0 && i < pace.length
                            ? Fmt.dayMonth(pace[i].date)
                            : '';
                      },
                    ),
            ),
            const SectionHeader('Distance trend', subtitle: 'km per run'),
            AppCard(
              child: dist.length < 2
                  ? const Text('Need at least two runs.')
                  : TrendLineChart(
                      points: [
                        for (var i = 0; i < dist.length; i++)
                          (i.toDouble(), dist[i].value / 1000),
                      ],
                      color: AppColors.running,
                      semanticLabel: 'Distance per run trend',
                      yLabel: (v) => v.toStringAsFixed(1),
                      xLabel: (v) {
                        final i = v.round();
                        return i >= 0 && i < dist.length
                            ? Fmt.dayMonth(dist[i].date)
                            : '';
                      },
                    ),
            ),
            const SectionHeader('Personal bests'),
            _BestsRow(bests: bests),
            const SectionHeader('Recent activities'),
            for (final a in all.take(20)) _ActivityTile(activity: a),
            if (hasStrava) const PoweredByStrava(),
          ],
        );
      },
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.best});
  final GoalProgress goal;
  final Best5k? best;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final goalLabel =
        '${(goal.goalDistanceM / 1000).toStringAsFixed(goal.goalDistanceM % 1000 == 0 ? 0 : 1)} km '
        'in ${Fmt.duration(goal.goalTimeS)}';
    return AppCard(
      accent: AppColors.running,
      semanticLabel: 'Goal progress',
      child: Row(
        children: [
          ProgressRing(
            progress: goal.fraction,
            color: goal.achieved ? AppColors.success : AppColors.running,
            size: 96,
            stroke: 10,
            semanticLabel: 'Progress toward $goalLabel',
            center: Text(
              goal.hasData ? '${(goal.fraction * 100).round()}%' : '—',
              style: t.titleMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Goal: $goalLabel', style: t.titleSmall),
                Text(
                  'Target pace ${Fmt.pace(goal.goalPaceSPerKm)}',
                  style: t.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                if (goal.goalDistanceM != 5000)
                  Text(
                    'Progress tracking currently supports 5 km goals.',
                    style: t.bodySmall,
                  )
                else if (best == null)
                  Text(
                    'No valid 5K yet. Run ≥ 5 km with splits (Strava) or a '
                    '4.9–5.3 km run to get an estimate.',
                    style: t.bodySmall,
                  )
                else ...[
                  Text(
                    'Best: ${Fmt.duration(best!.timeS)}'
                    '${goal.achieved ? ' — goal reached!' : ' · ${Fmt.duration(goal.gapS!)} to go'}',
                    style: t.bodyMedium,
                  ),
                  Text(
                    '${best!.label} · ${Fmt.dayMonth(best!.date)}',
                    style: t.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BestsRow extends StatelessWidget {
  const _BestsRow({required this.bests});
  final RunningBests bests;

  @override
  Widget build(BuildContext context) {
    Widget card(String label, String value, String? sub, String? id) =>
        Expanded(
          child: AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            onTap: id == null
                ? null
                : () => context.push('/running/activity/$id'),
            child: StatTile(label: label, value: value, sub: sub),
          ),
        );
    final b5 = bests.best5k;
    final longest = bests.longestRun;
    final fastest = bests.fastestPaceRun;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card(
          'Best 5K',
          b5 == null ? '—' : Fmt.duration(b5.timeS),
          b5 == null
              ? 'no valid data'
              : b5.method == Best5kMethod.splits
              ? 'from splits'
              : 'whole run',
          b5?.activityId,
        ),
        const SizedBox(width: AppSpacing.sm),
        card(
          'Longest',
          longest?.distanceM == null ? '—' : Fmt.km(longest!.distanceM!),
          longest == null ? null : Fmt.dayMonth(longest.startAt),
          longest?.id,
        ),
        const SizedBox(width: AppSpacing.sm),
        card(
          'Fastest ≥3 km',
          fastest == null ? '—' : Fmt.pace(fastest.paceSPerKm!),
          fastest == null ? null : Fmt.dayMonth(fastest.startAt),
          fastest?.id,
        ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.activity});
  final RunActivity activity;

  IconData get _icon => switch (activity.sportType) {
    'run' => Icons.directions_run,
    'walk' => Icons.directions_walk,
    'hike' => Icons.terrain,
    'ride' => Icons.directions_bike,
    _ => Icons.sports,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final a = activity;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon, color: AppColors.running),
      title: Text(a.name ?? _sportLabel(a.sportType)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              Fmt.weekdayDayMonth(a.startAt),
              if (a.distanceM != null) Fmt.km(a.distanceM!),
              if (a.timeS != null) Fmt.duration(a.timeS!),
              if (a.isRun && a.paceSPerKm != null) Fmt.pace(a.paceSPerKm!),
            ].join(' · '),
            style: t.bodySmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              SourceBadge(origin: DataOrigin.fromKey(a.source)),
              if (a.alsoInHealthConnect)
                Text('also in Health Connect', style: t.labelSmall),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/running/activity/${a.id}'),
    );
  }
}

String _sportLabel(String s) => switch (s) {
  'run' => 'Run',
  'walk' => 'Walk',
  'hike' => 'Hike',
  'ride' => 'Ride',
  _ => 'Activity',
};
