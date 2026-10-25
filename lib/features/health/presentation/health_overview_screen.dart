import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../train/presentation/widgets/hud_kit.dart';
import '../application/health_providers.dart';
import '../application/health_sync_service.dart';
import '../domain/aggregation.dart';
import '../domain/health_types.dart';
import '../domain/sources.dart';
import 'widgets/health_charts.dart';
import 'widgets/health_widgets.dart';

class HealthOverviewScreen extends ConsumerWidget {
  const HealthOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = ref.watch(healthDiagnosticsProvider).value;
    final groups = ref.watch(healthEnabledGroupsProvider).value;
    GroupAccess access(HealthGroup g) =>
        groupAccess(g, diagnostics: diag, enabled: groups);

    return AppPage(
      title: 'Health',
      eyebrow: 'HEALTH CONNECT + MANUAL · READ-ONLY',
      onRefresh: () =>
          runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh),
      actions: [
        IconButton(
          tooltip: 'Health Connect status',
          onPressed: () => context.push(AppPaths.healthStatus),
          icon: const Icon(Icons.tune),
        ),
      ],
      children: [
        const SyncStatusRow(),
        const SectionHeader(
          'Sleep',
          subtitle: 'Last 7 nights',
          accent: AppColors.sleep,
        ),
        _SleepCard(access: access(HealthGroup.sleep)),
        const SectionHeader('Weight', accent: AppColors.cyan),
        _WeightCard(access: access(HealthGroup.body)),
        const SectionHeader('Heart', accent: AppColors.heart),
        _HeartCard(access: access(HealthGroup.heart)),
        const SectionHeader(
          'Active energy',
          subtitle: 'Last 7 days',
          accent: AppColors.calories,
        ),
        _ActiveCaloriesCard(access: access(HealthGroup.activity)),
        const SectionHeader('Recent exercise', accent: AppColors.running),
        _ExerciseCard(access: access(HealthGroup.activity)),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Athlete OS shows what your apps and devices recorded. It does not '
          'diagnose medical conditions — talk to a clinician about health '
          'concerns.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: context.hud.textMuted),
        ),
      ],
    );
  }
}

/// Compact gate that distinguishes "not permitted" from "no data".
class _AccessGate extends ConsumerWidget {
  const _AccessGate({
    required this.access,
    required this.group,
    required this.icon,
    required this.color,
  });

  final GroupAccess access;
  final HealthGroup group;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (title, message, action, onAction) = switch (access) {
      GroupAccess.granted => ('', '', null, null),
      GroupAccess.unavailable => (
        'Health Connect not available',
        'Set up Health Connect to see ${group.label.toLowerCase()} data.',
        'Set up',
        () => context.push(AppPaths.healthStatus),
      ),
      GroupAccess.notEnabled => (
        '${group.label} data isn\'t shared',
        'You haven\'t allowed Athlete OS to read '
            '${group.label.toLowerCase()} data.',
        'Allow',
        () => showHealthPermissionSheet(context, ref, group),
      ),
      GroupAccess.notGranted => (
        'Permission not granted',
        '${group.label} permission is off in Health Connect (it may have '
            'been revoked).',
        'Grant',
        () => showHealthPermissionSheet(context, ref, group),
      ),
    };
    return _CompactState(
      icon: icon,
      color: color,
      title: title,
      message: message,
      action: action,
      onAction: onAction,
    );
  }
}

/// One-row empty/setup state: badge, title, message, optional action.
class _CompactState extends StatelessWidget {
  const _CompactState({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
    this.footer,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              HudBadge(icon: icon, color: color, size: 40),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall),
                    Text(
                      message,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: AppSpacing.sm),
                HudButton.secondary(
                  label: action!,
                  compact: true,
                  onPressed: onAction,
                ),
              ],
            ],
          ),
          ?footer,
        ],
      ),
    );
  }
}

String _hm(num minutes) {
  final m = minutes.round();
  return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}

class _SleepCard extends ConsumerWidget {
  const _SleepCard({required this.access});
  final GroupAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final hud = context.hud;
    final rows = ref.watch(
      dailySummariesProvider((HealthKeys.sleepMinutes, 7)),
    );
    final hasData = rows.value?.isNotEmpty ?? false;
    // Show stored data even if access was later revoked.
    if (!hasData && access != GroupAccess.granted) {
      return _AccessGate(
        access: access,
        group: HealthGroup.sleep,
        icon: Icons.bedtime_outlined,
        color: AppColors.sleep,
      );
    }
    return rows.when(
      loading: () => const ScanlineLoader(height: 120, lines: 0),
      error: (e, _) => const ErrorState(message: 'Could not load sleep.'),
      data: (list) {
        if (list.isEmpty) {
          return const _CompactState(
            icon: Icons.bedtime_outlined,
            color: AppColors.sleep,
            title: 'No sleep recorded in the last 7 nights',
            message:
                'Sleep needs an app or wearable that writes sleep sessions '
                'to Health Connect.',
          );
        }
        final byDate = {for (final r in list) r.localDate: r};
        final days = LocalDates.range(LocalDates.addDays(today, -6), today);
        final latest = list.last;
        final avg = list.fold<double>(0, (a, r) => a + r.value) / list.length;
        return AppCard(
          accent: AppColors.sleep,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: HudReadout(
                      label: latest.localDate == today
                          ? 'Last night'
                          : 'Latest night',
                      // "6 h 30 min", like the average (a clock-style "6:30 h"
                      // read as a time of day).
                      value:
                          '${latest.value.round() ~/ 60} h '
                          '${(latest.value.round() % 60).toString().padLeft(2, '0')}',
                      unit: 'min',
                      caption:
                          'ending ${Fmt.weekdayDayMonth(LocalDates.parse(latest.localDate))}',
                      size: 34,
                      color: AppColors.sleep,
                    ),
                  ),
                  HudReadout(
                    label: 'Average',
                    value: _hm(avg),
                    caption: '${list.length} nights',
                    size: 18,
                    crossAxisAlignment: CrossAxisAlignment.end,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              DailyBarChart(
                values: [
                  for (final d in days)
                    (
                      date: d,
                      value: byDate[d] == null ? null : byDate[d]!.value / 60,
                    ),
                ],
                color: AppColors.sleep,
                height: 130,
                formatValue: (h) => _hm(h * 60),
                semanticLabel: 'Sleep hours for the last 7 nights',
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  SourceBadge(
                    origin: DataOrigin.healthConnect,
                    asOf: latest.computedAt,
                    now: now,
                  ),
                  if (latest.sourcesSummary != null)
                    OriginChip(latest.sourcesSummary!),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Time in recorded sleep sessions, assigned to the morning '
                'the session ended.',
                style: hud.mono(size: 10),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeartCard extends ConsumerWidget {
  const _HeartCard({required this.access});
  final GroupAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final hr = ref.watch(recentSamplesProvider((HealthKeys.heartRate, 1)));
    final rhr = ref.watch(
      recentSamplesProvider((HealthKeys.restingHeartRate, 1)),
    );
    final latestHr = hr.value?.firstOrNull;
    final latestRhr = rhr.value?.firstOrNull;
    if (latestHr == null && latestRhr == null) {
      if (access != GroupAccess.granted) {
        return _AccessGate(
          access: access,
          group: HealthGroup.heart,
          icon: Icons.favorite_border,
          color: AppColors.heart,
        );
      }
      if (hr.isLoading || rhr.isLoading) {
        return const ScanlineLoader(height: 80, lines: 0);
      }
      return const _CompactState(
        icon: Icons.favorite_border,
        color: AppColors.heart,
        title: 'No heart-rate data yet',
        message:
            'Heart rate needs a watch or strap that writes to Health '
            'Connect; a phone alone can\'t measure it.',
      );
    }
    return AppCard(
      accent: AppColors.heart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SampleTile(label: 'Latest', sample: latestHr, now: now),
              ),
              Expanded(
                child: _SampleTile(
                  label: 'Resting',
                  sample: latestRhr,
                  now: now,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Readings as last synced, not real-time. Not for medical use.',
            style: context.hud.mono(size: 10),
          ),
        ],
      ),
    );
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({
    required this.label,
    required this.sample,
    required this.now,
  });

  final String label;
  final HealthSample? sample;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final s = sample;
    if (s == null) {
      return HudReadout(label: label, value: '–', caption: 'No data', size: 26);
    }
    final when = s.startAt.toLocal();
    final dateText = LocalDates.key(when) == LocalDates.key(now)
        ? Fmt.time(when)
        : '${Fmt.dayMonth(when)}, ${Fmt.time(when)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HudReadout(
          label: label,
          value: '${s.value.round()}',
          unit: 'bpm',
          caption: '$dateText · ${Fmt.ago(when, now)}',
          size: 28,
          color: AppColors.heart,
        ),
        const SizedBox(height: AppSpacing.xs),
        OriginChip(_sourceText(s)),
      ],
    );
  }
}

String _sourceText(HealthSample s) {
  if (s.origin == HealthKeys.originManual) return 'Manual entry';
  final device = deviceLabel(s.sourceDevice);
  return '${sourceAppLabel(s.sourceApp)} · $device';
}

class _WeightCard extends ConsumerWidget {
  const _WeightCard({required this.access});
  final GroupAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final rows = ref.watch(weightTrendProvider);
    final hud = context.hud;
    return rows.when(
      loading: () => const ScanlineLoader(height: 120, lines: 0),
      error: (e, _) => const ErrorState(message: 'Could not load weight.'),
      data: (list) {
        if (list.isEmpty) {
          return _CompactState(
            icon: Icons.monitor_weight_outlined,
            color: AppColors.cyan,
            title: 'No weight entries in the last 90 days',
            message: access == GroupAccess.granted
                ? 'Add one manually or weigh in with a scale that syncs to '
                      'Health Connect.'
                : 'Add one manually, or allow Body data from Health '
                      'Connect.',
            action: 'Add',
            onAction: () => showManualWeightDialog(context, ref),
            footer:
                access == GroupAccess.notEnabled ||
                    access == GroupAccess.notGranted
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: HudButton.ghost(
                      label: 'Allow Health Connect weight',
                      compact: true,
                      onPressed: () => showHealthPermissionSheet(
                        context,
                        ref,
                        HealthGroup.body,
                      ),
                    ),
                  )
                : null,
          );
        }
        return _WeightBody(list: list, now: now, hud: hud);
      },
    );
  }
}

class _WeightBody extends ConsumerStatefulWidget {
  const _WeightBody({required this.list, required this.now, required this.hud});
  final List<HealthSample> list;
  final DateTime now;
  final HudTheme hud;

  @override
  ConsumerState<_WeightBody> createState() => _WeightBodyState();
}

class _WeightBodyState extends ConsumerState<_WeightBody> {
  int? _scrub;

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final hud = widget.hud;
    final latest = list.last;
    final i = _scrub ?? list.length - 1;
    final shown = list[i];
    // Average of the first and last week of entries: steadier than two
    // single weigh-ins.
    double avgOf(Iterable<HealthSample> s) =>
        s.fold<double>(0, (a, x) => a + x.value) / s.length;
    final firstWeek = list.where(
      (s) => s.startAt.difference(list.first.startAt).inDays < 7,
    );
    final lastWeek = list.where(
      (s) => latest.startAt.difference(s.startAt).inDays < 7,
    );
    final change = list.length >= 4 ? avgOf(lastWeek) - avgOf(firstWeek) : null;
    final spanDays = latest.startAt.difference(list.first.startAt).inDays;
    return AppCard(
      accent: AppColors.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: HudReadout(
                  label: _scrub == null
                      ? 'Latest'
                      : Fmt.weekdayDayMonth(shown.startAt),
                  value: Fmt.oneDp(shown.value),
                  unit: 'kg',
                  caption: _sourceText(shown),
                  size: 34,
                ),
              ),
              if (change != null)
                HudReadout(
                  label: 'Trend · $spanDays d',
                  value: signed(change, unit: ' kg'),
                  caption: 'weekly averages',
                  size: 20,
                  color: hud.accentInk,
                  crossAxisAlignment: CrossAxisAlignment.end,
                ),
            ],
          ),
          if (list.length > 1) ...[
            const SizedBox(height: AppSpacing.md),
            HudLineChart(
              values: [for (final s in list) s.value],
              color: AppColors.cyan,
              height: 150,
              rollingWindow: list.length >= 6 ? 4 : null,
              rollingLabel: 'avg',
              semanticLabel:
                  'Weight trend, ${list.length} entries over 90 days',
              format: (v) => v.toStringAsFixed(1),
              xLabel: (i) => '${list[i].startAt.day}/${list[i].startAt.month}',
              tooltip: (i) =>
                  '${Fmt.dayMonth(list[i].startAt)} · '
                  '${Fmt.oneDp(list[i].value)} kg',
              onScrub: (s) => setState(() => _scrub = s),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          GlassPanel(
            radius: AppRadii.md,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.water_drop_outlined, size: 16, color: hud.accent),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Short-term changes aren\'t fat or muscle: day-to-day '
                    'scale moves are mostly water, food and glycogen. Judge '
                    'the trend over weeks.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              SourceBadge(
                origin: latest.origin == HealthKeys.originManual
                    ? DataOrigin.manual
                    : DataOrigin.healthConnect,
                asOf: latest.syncedAt,
                now: widget.now,
                staleAfter: const Duration(days: 7),
              ),
              const Spacer(),
              HudButton.secondary(
                label: 'Add weight',
                icon: Icons.add,
                compact: true,
                onPressed: () => showManualWeightDialog(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActiveCaloriesCard extends ConsumerWidget {
  const _ActiveCaloriesCard({required this.access});
  final GroupAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final rows = ref.watch(dailySummariesProvider((HealthKeys.activeKcal, 7)));
    final list = rows.value ?? const <DailyHealthSummary>[];
    if (list.isEmpty) {
      if (access != GroupAccess.granted) {
        return _AccessGate(
          access: access,
          group: HealthGroup.activity,
          icon: Icons.local_fire_department_outlined,
          color: AppColors.calories,
        );
      }
      if (rows.isLoading) return const ScanlineLoader(height: 80, lines: 0);
      return const _CompactState(
        icon: Icons.local_fire_department_outlined,
        color: AppColors.calories,
        title: 'No active calories in the last 7 days',
        message:
            'They appear once an app writes active energy to Health '
            'Connect.',
      );
    }
    final byDate = {for (final r in list) r.localDate: r};
    final days = LocalDates.range(LocalDates.addDays(today, -6), today);
    final todayRow = byDate[today];
    final avg = list.fold<double>(0, (a, r) => a + r.value) / list.length;
    return AppCard(
      accent: AppColors.calories,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Today',
                  value: todayRow == null ? '–' : Fmt.integer(todayRow.value),
                  unit: 'kcal',
                  size: 28,
                  color: AppColors.calories,
                ),
              ),
              HudReadout(
                label: 'Daily average',
                value: Fmt.integer(avg),
                unit: 'kcal',
                caption: '${list.length} days with data',
                size: 20,
                crossAxisAlignment: CrossAxisAlignment.end,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          DailyBarChart(
            values: [for (final d in days) (date: d, value: byDate[d]?.value)],
            color: AppColors.calories,
            height: 110,
            formatValue: Fmt.kcal,
            semanticLabel: 'Active calories for the last 7 days',
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              SourceBadge(
                origin: DataOrigin.healthConnect,
                asOf: list.last.computedAt,
                now: now,
              ),
              if (list.last.sourcesSummary != null)
                OriginChip(list.last.sourcesSummary!),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({required this.access});
  final GroupAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final hud = context.hud;
    final rows = ref.watch(
      recentSamplesProvider((HealthKeys.exerciseSession, 8)),
    );
    final list = rows.value ?? const <HealthSample>[];
    if (list.isEmpty) {
      if (access != GroupAccess.granted) {
        return _AccessGate(
          access: access,
          group: HealthGroup.activity,
          icon: Icons.fitness_center,
          color: AppColors.running,
        );
      }
      if (rows.isLoading) return const ScanlineLoader(height: 80, lines: 0);
      return const _CompactState(
        icon: Icons.fitness_center,
        color: AppColors.running,
        title: 'No exercise sessions recorded recently',
        message: 'Workouts tracked by your phone apps appear here after sync.',
      );
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        children: [
          for (final (i, s) in list.indexed)
            Builder(
              builder: (context) {
                Map<String, dynamic> meta = const {};
                try {
                  meta = s.metadataJson == null
                      ? const {}
                      : (jsonDecode(s.metadataJson!) as Map<String, dynamic>);
                } catch (_) {}
                final type = meta['workout_type'] as String?;
                final distance = (meta['distance_m'] as num?)?.toDouble();
                final sport = normaliseCardioSport(type);
                final parts = <String>[
                  Fmt.duration((s.value * 60).round()),
                  if (distance != null && distance > 0) Fmt.km(distance),
                  sourceAppLabel(s.sourceApp),
                ];
                return Column(
                  children: [
                    if (i > 0) const HudDivider(height: 1),
                    HudRow(
                      leading: HudBadge(
                        icon: sport == 'run'
                            ? Icons.directions_run
                            : sport == 'ride'
                            ? Icons.directions_bike
                            : sport != null
                            ? Icons.directions_walk
                            : Icons.fitness_center,
                        color: AppColors.running,
                      ),
                      title: workoutLabel(type),
                      subtitle:
                          '${Fmt.weekdayDayMonth(s.startAt)}, '
                          '${Fmt.time(s.startAt)} · ${parts.join(' · ')}',
                      trailing: Text(
                        Fmt.ago(s.startAt, now),
                        style: hud.mono(size: 10),
                      ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
