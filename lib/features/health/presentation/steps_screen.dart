import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/profile_repository.dart';
import '../application/health_providers.dart';
import '../application/health_sync_service.dart';
import '../domain/health_types.dart';
import '../domain/steps_math.dart';
import 'widgets/health_charts.dart';
import 'widgets/health_widgets.dart';

class StepsScreen extends ConsumerStatefulWidget {
  const StepsScreen({super.key});

  @override
  ConsumerState<StepsScreen> createState() => _StepsScreenState();
}

class _StepsScreenState extends ConsumerState<StepsScreen> {
  int _rangeDays = 7;

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final history = ref.watch(stepsHistoryProvider(30));
    final profile = ref.watch(profileProvider).value;
    final diag = ref.watch(healthDiagnosticsProvider);
    final groups = ref.watch(healthEnabledGroupsProvider).value;
    final conn = ref.watch(healthConnectionProvider).value;

    final goal = profile?.stepGoal ?? 0;
    final window = WakingWindow(
      wakeMinutes: profile?.wakeMinutes ?? 390,
      sleepMinutes: profile?.sleepMinutes ?? 1350,
    );
    final access = groupAccess(
      HealthGroup.activity,
      diagnostics: diag.value,
      enabled: groups,
    );
    final stepsGranted =
        access == GroupAccess.granted &&
        (diag.value?.granted(HcDataType.steps) ?? false);

    return AppPage(
      title: 'Steps',
      onRefresh: () =>
          runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh),
      actions: const [SyncButton(compact: true)],
      children: history.when(
        loading: () => const [LoadingState()],
        error: (e, _) => [
          ErrorState(
            message: 'Could not load steps.',
            onRetry: () => ref.invalidate(stepsHistoryProvider(30)),
          ),
        ],
        data: (byDay) {
          final todaySteps = byDay[today];
          final children = <Widget>[];
          if (todaySteps == null && !stepsGranted && !diag.isLoading) {
            children.add(
              _StepsUnavailableCard(access: access, localDate: today),
            );
          } else if (todaySteps == null) {
            children.add(_NoStepsTodayCard(localDate: today));
          } else {
            children.add(
              _TodayCard(
                day: todaySteps,
                goal: goal,
                now: now,
                window: window,
                lastSyncAt: conn?.lastSyncAt,
                localDate: today,
              ),
            );
            if (todaySteps.origin == HealthKeys.originHc &&
                !stepsGranted &&
                !diag.isLoading) {
              children.add(
                NoticeBanner(
                  message:
                      'Health Connect step access is currently off, so this '
                      'is the last synced value.',
                  color: AppColors.warning,
                  icon: Icons.lock_outline,
                  actionLabel: 'Fix',
                  onAction: () => context.push(AppPaths.healthStatus),
                ),
              );
            }
          }
          children.add(const SyncStatusRow());
          children.add(
            _HistoryCard(
              byDay: byDay,
              goal: goal,
              rangeDays: _rangeDays,
              onRange: (d) => setState(() => _rangeDays = d),
            ),
          );
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showManualStepsDialog(
                  context,
                  ref,
                  localDate: today,
                  initial: todaySteps?.isManual ?? false
                      ? todaySteps!.steps
                      : todaySteps?.overriddenManual,
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Enter steps manually'),
              ),
            ),
          );
          return spaced(children);
        },
      ),
    );
  }
}

class _StepsUnavailableCard extends ConsumerWidget {
  const _StepsUnavailableCard({required this.access, required this.localDate});
  final GroupAccess access;
  final String localDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = switch (access) {
      GroupAccess.unavailable =>
        'Health Connect is not available or not installed on this phone.',
      GroupAccess.notEnabled =>
        'Activity data sharing from Health Connect is not set up yet.',
      GroupAccess.notGranted || GroupAccess.granted =>
        'Health Connect step permission is not granted (it may have been '
            'revoked).',
    };
    return AppCard(
      accent: AppColors.steps,
      semanticLabel: 'Step data unavailable',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EmptyState(
            icon: Icons.directions_walk,
            title: 'The app cannot currently access step data',
            message: reason,
            compact: true,
          ),
          FilledButton.icon(
            onPressed: () => context.push(AppPaths.healthStatus),
            icon: const Icon(Icons.health_and_safety_outlined),
            label: const Text('Set up Health Connect'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () =>
                showManualStepsDialog(context, ref, localDate: localDate),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Enter steps manually'),
          ),
        ],
      ),
    );
  }
}

class _NoStepsTodayCard extends ConsumerWidget {
  const _NoStepsTodayCard({required this.localDate});
  final String localDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const EmptyState(
            icon: Icons.directions_walk,
            title: 'No step data for today yet',
            message:
                'Sync to fetch today\'s steps from Health Connect. If it stays '
                'empty, check that Samsung Health is syncing to Health '
                'Connect.',
            compact: true,
          ),
          const SyncButton(),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () =>
                showManualStepsDialog(context, ref, localDate: localDate),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Enter steps manually'),
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.day,
    required this.goal,
    required this.now,
    required this.window,
    required this.lastSyncAt,
    required this.localDate,
  });

  final DaySteps day;
  final int goal;
  final DateTime now;
  final WakingWindow window;
  final DateTime? lastSyncAt;
  final String localDate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final p = stepsProgress(day.steps, goal);
    final perHour = stepsPerRemainingHour(
      steps: day.steps,
      goal: goal,
      now: now,
      window: window,
    );
    final pace = checkPace(
      steps: day.steps,
      goal: goal,
      now: now,
      window: window,
    );
    final bedtime = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(Duration(minutes: window.sleepMinutes % 1440));

    final String paceText;
    if (!p.hasGoal) {
      paceText = 'Set a step goal in Profile to see your pace.';
    } else if (p.goalMet) {
      paceText = 'Goal reached — nice work.';
    } else if (perHour == null) {
      paceText = 'It\'s past your usual bedtime, so there\'s no pace estimate.';
    } else {
      paceText =
          '≈ ${Fmt.integer(perHour)} steps per waking hour until '
          '${Fmt.time(bedtime)} (estimate)';
    }

    final asOf = day.isManual ? day.computedAt : (lastSyncAt ?? day.computedAt);

    return AppCard(
      accent: AppColors.steps,
      semanticLabel:
          'Steps today ${Fmt.integer(day.steps)}'
          '${p.hasGoal ? ' of ${Fmt.integer(goal)}' : ''}',
      child: Column(
        children: [
          ProgressRing(
            progress: p.fraction,
            color: AppColors.steps,
            size: 200,
            stroke: 16,
            semanticLabel: 'Step goal progress',
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Fmt.integer(day.steps), style: t.displaySmall),
                Text(
                  p.hasGoal ? 'of ${Fmt.integer(goal)}' : 'steps',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Remaining',
                  value: p.hasGoal ? Fmt.integer(p.remaining) : '–',
                  icon: Icons.flag_outlined,
                  color: AppColors.steps,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Progress',
                  value: p.hasGoal ? '${p.percent}%' : '–',
                  icon: Icons.percent,
                  color: AppColors.steps,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            label: paceText,
            excludeSemantics: true,
            child: Row(
              children: [
                Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(paceText, style: t.bodyMedium)),
              ],
            ),
          ),
          if (pace.behind) ...[
            const SizedBox(height: AppSpacing.md),
            NoticeBanner(
              icon: Icons.directions_walk,
              color: AppColors.steps,
              message:
                  'A bit behind your usual pace for this time of day '
                  '(${Fmt.integer(pace.steps)} vs ~'
                  '${Fmt.integer(pace.expectedByNow)} expected). A short '
                  'walk would help.',
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SourceBadge(
                origin: day.isManual
                    ? DataOrigin.manual
                    : DataOrigin.healthConnect,
                asOf: asOf,
                now: now,
              ),
              if (day.isManual) const OriginChip('Manual entry'),
              if (!day.isManual && day.sourcesSummary != null)
                OriginChip('From ${day.sourcesSummary}'),
            ],
          ),
          if (day.overriddenManual != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Your manual entry (${Fmt.integer(day.overriddenManual!)}) is '
              'overridden: Health Connect data is measured and de-duplicated '
              'across phone and watch, so it takes precedence.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.byDay,
    required this.goal,
    required this.rangeDays,
    required this.onRange,
  });

  final Map<String, DaySteps?> byDay;
  final int goal;
  final int rangeDays;
  final ValueChanged<int> onRange;

  @override
  Widget build(BuildContext context) {
    final keys = byDay.keys.toList()..sort();
    final shown = keys.sublist(keys.length - rangeDays.clamp(0, keys.length));
    final values = [
      for (final d in shown) (date: d, value: byDay[d]?.steps.toDouble()),
    ];
    Map<String, int?> counts(Iterable<String> days) => {
      for (final d in days) d: byDay[d]?.steps,
    };
    final s7 = stepsStats(counts(keys.skip(keys.length - 7)), goal);
    final s30 = stepsStats(counts(keys), goal);
    final hasAny = values.any((v) => v.value != null);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'History',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                ],
                selected: {rangeDays},
                onSelectionChanged: (s) => onRange(s.first),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (!hasAny)
            const EmptyState(
              icon: Icons.bar_chart,
              title: 'No step history yet',
              message: 'Days without data are left blank, never shown as 0.',
              compact: true,
            )
          else
            DailyBarChart(
              values: values,
              color: AppColors.steps,
              goal: goal > 0 ? goal.toDouble() : null,
              highlight: (d) => byDay[d]?.isManual ?? false,
              formatValue: (v) => Fmt.integer(v),
              semanticLabel:
                  'Steps for the last $rangeDays days'
                  '${goal > 0 ? ', goal ${Fmt.integer(goal)}' : ''}',
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '7-day average',
                  value: s7.average == null ? '–' : Fmt.integer(s7.average!),
                  sub: '${s7.goalHitDays}/${s7.daysWithData} goal days',
                ),
              ),
              Expanded(
                child: StatTile(
                  label: '30-day average',
                  value: s30.average == null ? '–' : Fmt.integer(s30.average!),
                  sub: '${s30.goalHitDays}/${s30.daysWithData} goal days',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Averages include only days with data. Faded bars are manual '
            'entries; the dashed line is your goal.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
