import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/config/env.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/training_program.dart';
import '../application/train_providers.dart';
import '../domain/running_analytics.dart';
import '../domain/running_models.dart';
import 'widgets/hud_kit.dart';
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
    final program = ref.watch(activeProgramProvider).value;

    Future<void> refresh() async {
      if (Env.hasStrava && isConnected(strava)) {
        await ref.read(syncControllerProvider.notifier).syncStrava();
      }
    }

    return async.when(
      loading: () => const AppPage(
        title: 'Running',
        children: [ScanlineLoader(height: 200, lines: 0)],
      ),
      error: (e, _) => const AppPage(
        title: 'Running',
        children: [ErrorState(message: 'Could not load activities.')],
      ),
      data: (all) {
        final runs = all.where((a) => a.isRun).toList();
        final bests = runningBests(runs);
        final goal = goalProgress(
          bests.best5k,
          goalTimeS: goalTime,
          goalDistanceM: goalDist,
        );
        final eyebrow =
            '${(goalDist / 1000).toStringAsFixed(goalDist % 1000 == 0 ? 0 : 1)}K '
            'GOAL < ${Fmt.duration(goalTime)} · '
            '${Fmt.pace(goal.goalPaceSPerKm).toUpperCase()}';
        if (all.isEmpty) {
          return AppPage(
            title: 'Running',
            eyebrow: eyebrow,
            onRefresh: refresh,
            children: [
              _GoalCard(goal: goal, best: null),
              const SizedBox(height: AppSpacing.md),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const HudRow(
                      leading: HudBadge(
                        icon: Icons.directions_run,
                        color: AppColors.running,
                      ),
                      title: 'No runs yet',
                      subtitle:
                          'Runs arrive from Strava or Health Connect '
                          'exercise sessions. Then pace trends, splits '
                          'and your 5K estimate light up.',
                      chevron: false,
                    ),
                    if (program != null) ...[
                      const HudDivider(),
                      for (final d in [
                        for (var i = 0; i < 7; i++)
                          program.sessionFor(
                            LocalDates.addDays(LocalDates.weekStart(today), i),
                          ),
                      ].where((d) => d.run != null))
                        HudRow(
                          leading: const HudBadge(
                            icon: Icons.route_outlined,
                            color: AppColors.running,
                            size: 36,
                          ),
                          title: '${weekdayShort[d.weekday - 1]} · ${d.title}',
                          subtitle:
                              '${d.run!.minutes} min · '
                              '${formatPaceRange(d.run!.paceMinS, d.run!.paceMaxS)} '
                              '(estimate)',
                          chevron: false,
                        ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    HudButton.secondary(
                      label: 'Connect apps',
                      icon: Icons.hub_outlined,
                      expand: true,
                      onPressed: () => context.push(AppPaths.integrations),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    HudButton.ghost(
                      label: 'See this week\'s run plan',
                      icon: Icons.route_outlined,
                      expand: true,
                      onPressed: () =>
                          context.push('${AppPaths.program}?hero=running'),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        final weeks = weeklyRunning(all, todayKey: today, weeks: 8);
        final consistency = runConsistency(all, todayKey: today);
        final pace = paceTrend(runs);
        final hasStrava = all.any((a) => a.isStrava);
        return AppPage(
          title: 'Running',
          eyebrow: eyebrow,
          onRefresh: refresh,
          children: [
            _GoalCard(goal: goal, best: bests.best5k),
            const SizedBox(height: AppSpacing.md),
            _WeeklyCard(weeks: weeks, consistency: consistency),
            const SectionHeader(
              'Pace trend',
              subtitle: 'Line = 4-run average',
              accent: AppColors.running,
            ),
            AppCard(
              child: pace.length < 2
                  ? Text(
                      'Need at least two runs of 1 km or more.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : HudLineChart(
                      values: [for (final p in pace) p.value],
                      color: AppColors.running,
                      invert: true,
                      rollingWindow: 4,
                      rollingLabel: '4-run avg',
                      reference: goal.goalPaceSPerKm,
                      referenceLabel:
                          'GOAL ${Fmt.pace(goal.goalPaceSPerKm).replaceAll(' /km', '')}',
                      semanticLabel:
                          'Pace trend. Latest ${Fmt.pace(pace.last.value)}',
                      format: (v) => Fmt.pace(v).replaceAll(' /km', ''),
                      xLabel: (i) =>
                          '${pace[i].date.day}/${pace[i].date.month}',
                      tooltip: (i) =>
                          '${Fmt.dayMonth(pace[i].date)} · '
                          '${Fmt.pace(pace[i].value)}',
                    ),
            ),
            const SectionHeader('Personal bests'),
            _BestsRow(bests: bests),
            const SectionHeader('Recent activities'),
            AppCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: StaggeredList(
                gap: 0,
                children: [
                  for (final (i, a) in all.take(20).indexed) ...[
                    if (i > 0) const HudDivider(height: 1),
                    _ActivityTile(activity: a),
                  ],
                ],
              ),
            ),
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
    final hud = context.hud;
    final b = best;
    final color = goal.achieved ? AppColors.gold : AppColors.running;
    final bestPace = b == null ? null : b.timeS / 5;
    return AppCard(
      accent: color,
      brackets: true,
      glow: goal.achieved,
      semanticLabel: 'Goal progress',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('5K goal', style: t.titleSmall),
              const SizedBox(width: AppSpacing.sm),
              const HudTag('ESTIMATE', color: AppColors.warning),
              const Spacer(),
              Text(
                'TARGET ${Fmt.duration(goal.goalTimeS)}',
                style: hud.mono(size: 11, color: hud.accentInk),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ArcGauge(
                value: goal.fraction,
                valueText: b == null ? '—' : Fmt.duration(b.timeS),
                label: 'BEST 5K',
                color: color,
                width: 160,
                stroke: 9,
                semanticLabel:
                    'Best 5K estimate versus the ${Fmt.duration(goal.goalTimeS)} goal',
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HudReadout(
                      label: goal.achieved ? 'Goal' : 'To cut',
                      value: !goal.hasData
                          ? '—'
                          : goal.achieved
                          ? 'Reached'
                          : Fmt.duration(goal.gapS!),
                      size: 24,
                      color: goal.achieved ? AppColors.gold : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    HudReadout(
                      label: 'Best pace',
                      value: bestPace == null
                          ? '—'
                          : Fmt.pace(bestPace).replaceAll(' /km', ''),
                      unit: bestPace == null ? null : '/km',
                      caption:
                          'goal ${Fmt.pace(goal.goalPaceSPerKm).replaceAll(' /km', '')} /km',
                      size: 22,
                      color: AppColors.running,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            goal.goalDistanceM != 5000
                ? 'Progress tracking currently supports 5 km goals.'
                : b == null
                ? 'No valid 5K yet. A run ≥ 5 km with splits (Strava) or a '
                      '4.9–5.3 km run gives an estimate.'
                : '${b.label} · ${Fmt.dayMonth(b.date)}. An estimate from '
                      'your runs, not a race result.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

class _WeeklyCard extends StatefulWidget {
  const _WeeklyCard({required this.weeks, required this.consistency});
  final List<WeekRunning> weeks;
  final RunConsistency consistency;

  @override
  State<_WeeklyCard> createState() => _WeeklyCardState();
}

class _WeeklyCardState extends State<_WeeklyCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final weeks = widget.weeks;
    final i = _sel ?? weeks.length - 1;
    final w = weeks[i];
    final c = widget.consistency;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: HudReadout(
                  label: i == weeks.length - 1
                      ? 'This week'
                      : 'Week of ${weekLabel(w.weekStart)}',
                  value: (w.distanceM / 1000).toStringAsFixed(1),
                  unit: 'km',
                  caption: '${w.runs} run${w.runs == 1 ? '' : 's'}',
                  size: 32,
                ),
              ),
              HudReadout(
                label: 'Consistency',
                value: '${c.weeksWithRuns}/${c.weeks}',
                unit: 'wks',
                caption: '${c.currentStreakWeeks}-week streak',
                size: 22,
                crossAxisAlignment: CrossAxisAlignment.end,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          HudBarChart(
            values: [for (final w in weeks) w.distanceM / 1000],
            labels: [for (final w in weeks) weekLabel(w.weekStart)],
            color: AppColors.running,
            highlight: i,
            height: 140,
            semanticLabel: 'Weekly running distance for 8 weeks',
            tooltip: (i, v) =>
                '${(v ?? 0).toStringAsFixed(1)} km · ${weeks[i].runs} runs',
            onSelect: (s) {
              if (s != null) setState(() => _sel = s);
            },
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
    Widget card(
      String label,
      String value,
      String? sub,
      String? id,
    ) => Expanded(
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: id == null ? null : () => context.push('/running/activity/$id'),
        child: HudReadout(label: label, value: value, caption: sub, size: 20),
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
          longest?.distanceM == null
              ? '—'
              : (longest!.distanceM! / 1000).toStringAsFixed(1),
          longest == null ? null : 'km · ${Fmt.dayMonth(longest.startAt)}',
          longest?.id,
        ),
        const SizedBox(width: AppSpacing.sm),
        card(
          'Fastest',
          fastest == null
              ? '—'
              : Fmt.pace(fastest.paceSPerKm!).replaceAll(' /km', ''),
          fastest == null ? null : '/km · ≥ 3 km',
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
    final hud = context.hud;
    final a = activity;
    return HudRow(
      leading: HudBadge(icon: _icon, color: AppColors.running),
      title: a.name ?? _sportLabel(a.sportType),
      subtitle: [
        Fmt.weekdayDayMonth(a.startAt),
        if (a.distanceM != null) Fmt.km(a.distanceM!),
        if (a.isRun && a.paceSPerKm != null) Fmt.pace(a.paceSPerKm!),
      ].join(' · '),
      footer: Wrap(
        spacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SourceBadge(origin: DataOrigin.fromKey(a.source)),
          if (a.alsoInHealthConnect)
            Text('also in Health Connect', style: hud.mono(size: 10)),
        ],
      ),
      trailing: a.timeS == null
          ? null
          : Text(Fmt.duration(a.timeS!), style: hud.number(size: 17)),
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
