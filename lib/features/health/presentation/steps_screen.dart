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
import '../../train/presentation/widgets/hud_kit.dart';
import '../application/health_providers.dart';
import '../application/health_sync_service.dart';
import '../domain/health_types.dart';
import '../domain/steps_math.dart';
import 'widgets/health_charts.dart';
import 'widgets/health_widgets.dart';

/// Steps: a reactor ring for today (remaining = max(0, goal − steps), a
/// per-waking-hour estimate), 7/30-day history and manual entry. Never
/// shows a fabricated number: without access it explains how to get one.
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
    final wake = profile?.wakeMinutes ?? 390;
    final sleep = profile?.sleepMinutes ?? 1350;
    final window = WakingWindow(wakeMinutes: wake, sleepMinutes: sleep);
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
      eyebrow: [
        if (goal > 0) 'GOAL ${Fmt.integer(goal)}',
        'AWAKE ${clockLabel(wake)}–${clockLabel(sleep)}',
      ].join(' · '),
      onRefresh: () =>
          runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh),
      actions: const [SyncButton(compact: true)],
      children: history.when(
        loading: () => const [ScanlineLoader(height: 260, lines: 0)],
        error: (e, _) => [
          ErrorState(
            message: 'Could not load steps.',
            onRetry: () => ref.invalidate(stepsHistoryProvider(30)),
          ),
        ],
        data: (byDay) {
          final todaySteps = byDay[today];
          final hasHcData = byDay.values.any((d) => d != null && !d.isManual);
          final children = <Widget>[];
          if (todaySteps == null && !stepsGranted && !diag.isLoading) {
            children.add(
              _StepsSetupCard(
                access: access,
                localDate: today,
                goal: goal,
                hcInstalled: diag.value?.sdk == HcSdkStatus.available,
                hasStepData: hasHcData,
                synced: conn?.lastSyncAt != null,
              ),
            );
          } else if (todaySteps == null) {
            children.add(_NoStepsTodayCard(localDate: today, goal: goal));
          } else {
            children.add(
              _TodayCard(
                day: todaySteps,
                goal: goal,
                now: now,
                window: window,
                lastSyncAt: conn?.lastSyncAt,
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
            HudButton.ghost(
              label: 'Enter steps manually',
              icon: Icons.edit_outlined,
              expand: true,
              onPressed: () => showManualStepsDialog(
                context,
                ref,
                localDate: today,
                initial: todaySteps?.isManual ?? false
                    ? todaySteps!.steps
                    : todaySteps?.overriddenManual,
              ),
            ),
          );
          return spaced(children);
        },
      ),
    );
  }
}

/// The ring with a center readout, shared by all states.
class _StepsRing extends StatelessWidget {
  const _StepsRing({
    required this.progress,
    required this.value,
    required this.sub,
    this.dim = false,
    this.size = 216,
  });
  final double progress;
  final String value;
  final String sub;
  final bool dim;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return ProgressRing(
      progress: progress,
      color: AppColors.steps,
      size: size,
      stroke: size * 0.07,
      semanticLabel: 'Step goal progress',
      center: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('TODAY', style: hud.label(size: 11)),
          AnimatedTicker(
            value,
            style: hud.number(
              size: size * 0.21,
              color: dim ? hud.textMuted : hud.text,
            ),
          ),
          Text(
            sub,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

class _StepsSetupCard extends ConsumerWidget {
  const _StepsSetupCard({
    required this.access,
    required this.localDate,
    required this.goal,
    required this.hcInstalled,
    required this.hasStepData,
    required this.synced,
  });
  final GroupAccess access;
  final String localDate;
  final int goal;
  final bool hcInstalled;
  final bool hasStepData;
  final bool synced;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
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
      brackets: true,
      semanticLabel: 'Step data unavailable',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _StepsRing(
              progress: 0,
              value: '—',
              sub: goal > 0 ? 'goal ${Fmt.integer(goal)}' : 'no goal set',
              dim: true,
              size: 168,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'The app cannot currently access step data',
            style: t.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            reason,
            style: t.bodySmall?.copyWith(color: hud.textMuted),
            textAlign: TextAlign.center,
          ),
          const HudDivider(height: AppSpacing.xl),
          HudSteps(
            steps: stepsSetup(
              hcInstalled: hcInstalled,
              hasStepData: hasStepData,
              granted: access == GroupAccess.granted,
              synced: synced,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(
            label: 'Set up Health Connect',
            icon: Icons.health_and_safety_outlined,
            expand: true,
            onPressed: () => context.push(AppPaths.healthStatus),
          ),
          const SizedBox(height: AppSpacing.sm),
          HudButton.secondary(
            label: 'Enter steps manually',
            icon: Icons.edit_outlined,
            expand: true,
            onPressed: () =>
                showManualStepsDialog(context, ref, localDate: localDate),
          ),
        ],
      ),
    );
  }
}

class _NoStepsTodayCard extends ConsumerWidget {
  const _NoStepsTodayCard({required this.localDate, required this.goal});
  final String localDate;
  final int goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      accent: AppColors.steps,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _StepsRing(
              progress: 0,
              value: '—',
              sub: goal > 0 ? 'goal ${Fmt.integer(goal)}' : 'steps',
              dim: true,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'No step data for today yet',
            style: t.titleSmall,
            textAlign: TextAlign.center,
          ),
          Text(
            'Sync to fetch today\'s steps from Health Connect. If it stays '
            'empty, check that your step-counting app writes to Health '
            'Connect.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          const SyncButton(),
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
  });

  final DaySteps day;
  final int goal;
  final DateTime now;
  final WakingWindow window;
  final DateTime? lastSyncAt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
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
      brackets: true,
      glow: p.goalMet,
      semanticLabel:
          'Steps today ${Fmt.integer(day.steps)}'
          '${p.hasGoal ? ' of ${Fmt.integer(goal)}' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _StepsRing(
              progress: p.hasGoal ? p.fraction : 0,
              value: Fmt.integer(day.steps),
              sub: p.hasGoal ? 'of ${Fmt.integer(goal)}' : 'steps',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Remaining',
                  value: p.hasGoal ? Fmt.integer(p.remaining) : '–',
                  size: 24,
                  color: p.goalMet ? AppColors.success : null,
                ),
              ),
              Expanded(
                child: HudReadout(
                  label: 'Progress',
                  value: p.hasGoal ? '${p.percent}%' : '–',
                  size: 24,
                  color: AppColors.steps,
                ),
              ),
              Expanded(
                child: HudReadout(
                  label: 'Needed / hr',
                  value: perHour == null ? '–' : Fmt.integer(perHour),
                  size: 24,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          GlassPanel(
            padding: const EdgeInsets.all(AppSpacing.md),
            radius: AppRadii.md,
            child: Semantics(
              label: paceText,
              excludeSemantics: true,
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: hud.accent),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(paceText, style: t.bodySmall)),
                ],
              ),
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
              'across apps and devices, so it takes precedence.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
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
    final hud = context.hud;
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'History',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              SizedBox(
                width: 160,
                child: SegmentedHud<int>(
                  segments: const [
                    HudSegment(value: 7, label: '7 days'),
                    HudSegment(value: 30, label: '30 days'),
                  ],
                  value: rangeDays,
                  onChanged: onRange,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (!hasAny)
            SizedBox(
              height: 120,
              child: Center(
                child: Text(
                  'No step history yet. Days without data stay blank, '
                  'never 0.',
                  textAlign: TextAlign.center,
                  style: hud.mono(size: 11),
                ),
              ),
            )
          else
            AnimatedSwitcher(
              duration: AppMotion.medium,
              child: DailyBarChart(
                key: ValueKey(rangeDays),
                values: values,
                color: AppColors.steps,
                goal: goal > 0 ? goal.toDouble() : null,
                goalLabel: goal > 0
                    ? 'GOAL ${(goal / 1000).toStringAsFixed(goal % 1000 == 0 ? 0 : 1)}K'
                    : null,
                highlight: (d) => byDay[d]?.isManual ?? false,
                formatValue: (v) => '${Fmt.integer(v)} steps',
                semanticLabel:
                    'Steps for the last $rangeDays days'
                    '${goal > 0 ? ', goal ${Fmt.integer(goal)}' : ''}',
              ),
            ),
          const HudDivider(),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '7-day average',
                  value: s7.average == null ? '–' : Fmt.integer(s7.average!),
                  sub: '${s7.goalHitDays}/${s7.daysWithData} goal days',
                  color: AppColors.steps,
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
            style: hud.mono(size: 10),
          ),
        ],
      ),
    );
  }
}
