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
      subtitle: 'From Health Connect and your manual entries',
      onRefresh: () =>
          runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh),
      actions: [
        IconButton(
          tooltip: 'Health Connect status',
          onPressed: () => context.push(AppPaths.healthStatus),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
      children: [
        const SyncStatusRow(),
        const SectionHeader('Sleep', subtitle: 'Last 7 nights'),
        _SleepCard(access: access(HealthGroup.sleep)),
        const SectionHeader('Heart'),
        _HeartCard(access: access(HealthGroup.heart)),
        const SectionHeader('Weight'),
        _WeightCard(access: access(HealthGroup.body)),
        const SectionHeader('Active calories', subtitle: 'Last 7 days'),
        _ActiveCaloriesCard(access: access(HealthGroup.activity)),
        const SectionHeader('Recent exercise'),
        _ExerciseCard(access: access(HealthGroup.activity)),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Athlete OS shows what your apps and devices recorded. It does not '
          'diagnose medical conditions — talk to a clinician about health '
          'concerns.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Empty state that distinguishes "not permitted" from "no data".
class _AccessGate extends ConsumerWidget {
  const _AccessGate({
    required this.access,
    required this.group,
    required this.icon,
    required this.child,
  });

  final GroupAccess access;
  final HealthGroup group;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (access) {
      GroupAccess.granted => child,
      GroupAccess.unavailable => AppCard(
        child: EmptyState(
          icon: icon,
          title: 'Health Connect not available',
          message:
              'Set up Health Connect to see ${group.label.toLowerCase()} '
              'data.',
          actionLabel: 'Set up',
          onAction: () => context.push(AppPaths.healthStatus),
          compact: true,
        ),
      ),
      GroupAccess.notEnabled => AppCard(
        child: EmptyState(
          icon: icon,
          title: '${group.label} data isn\'t shared',
          message:
              'You haven\'t allowed Athlete OS to read '
              '${group.label.toLowerCase()} data.',
          actionLabel: 'Allow access',
          onAction: () => showHealthPermissionSheet(context, ref, group),
          compact: true,
        ),
      ),
      GroupAccess.notGranted => AppCard(
        child: EmptyState(
          icon: icon,
          title: 'Permission not granted',
          message:
              '${group.label} permission is off in Health Connect '
              '(it may have been revoked).',
          actionLabel: 'Grant access',
          onAction: () => showHealthPermissionSheet(context, ref, group),
          compact: true,
        ),
      ),
    };
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
        child: const SizedBox.shrink(),
      );
    }
    return rows.when(
      loading: () => const LoadingState(),
      error: (e, _) => const ErrorState(message: 'Could not load sleep.'),
      data: (list) {
        if (list.isEmpty) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.bedtime_outlined,
              title: 'No sleep recorded in the last 7 nights',
              message:
                  'Wear your watch to bed and keep Samsung Health syncing to '
                  'Health Connect.',
              compact: true,
            ),
          );
        }
        final byDate = {for (final r in list) r.localDate: r};
        final days = LocalDates.range(LocalDates.addDays(today, -6), today);
        final latest = list.last;
        return AppCard(
          accent: AppColors.sleep,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatTile(
                label: latest.localDate == today
                    ? 'Last night'
                    : 'Latest night',
                value: _hm(latest.value),
                sub:
                    'Night ending ${Fmt.weekdayDayMonth(LocalDates.parse(latest.localDate))}',
                icon: Icons.bedtime_outlined,
                color: AppColors.sleep,
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
                formatValue: (h) => _hm(h * 60),
                semanticLabel: 'Sleep hours for the last 7 nights',
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
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
                'Time in recorded sleep sessions, assigned to the morning the '
                'session ended.',
                style: Theme.of(context).textTheme.bodySmall,
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
          child: const SizedBox.shrink(),
        );
      }
      if (hr.isLoading || rhr.isLoading) return const LoadingState();
      return const AppCard(
        child: EmptyState(
          icon: Icons.favorite_border,
          title: 'No heart-rate data yet',
          message:
              'Watch heart rate reaches Health Connect with a delay after '
              'Samsung Health syncs.',
          compact: true,
        ),
      );
    }
    return AppCard(
      accent: AppColors.heart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _SampleTile(
                  label: 'Latest heart rate',
                  sample: latestHr,
                  unit: 'bpm',
                  now: now,
                ),
              ),
              Expanded(
                child: _SampleTile(
                  label: 'Resting heart rate',
                  sample: latestRhr,
                  unit: 'bpm',
                  now: now,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Readings as last synced, not live. Watch heart rate syncs to '
            'Health Connect with a delay. Not for medical use.',
            style: Theme.of(context).textTheme.bodySmall,
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
    required this.unit,
    required this.now,
  });

  final String label;
  final HealthSample? sample;
  final String unit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final s = sample;
    if (s == null) {
      return StatTile(label: label, value: '–', sub: 'No data');
    }
    final when = s.startAt.toLocal();
    final dateText = LocalDates.key(when) == LocalDates.key(now)
        ? Fmt.time(when)
        : '${Fmt.dayMonth(when)}, ${Fmt.time(when)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatTile(
          label: label,
          value: '${s.value.round()} $unit',
          sub: '$dateText · ${Fmt.ago(when, now)}',
          icon: Icons.favorite,
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
    final t = Theme.of(context).textTheme;
    return rows.when(
      loading: () => const LoadingState(),
      error: (e, _) => const ErrorState(message: 'Could not load weight.'),
      data: (list) {
        final addButton = OutlinedButton.icon(
          onPressed: () => showManualWeightDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Add weight'),
        );
        if (list.isEmpty) {
          return AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EmptyState(
                  icon: Icons.monitor_weight_outlined,
                  title: 'No weight entries in the last 90 days',
                  message: access == GroupAccess.granted
                      ? 'Add one manually or weigh in with a scale that '
                            'syncs to Health Connect.'
                      : 'Add one manually, or allow Body data from Health '
                            'Connect.',
                  compact: true,
                ),
                addButton,
                if (access == GroupAccess.notEnabled ||
                    access == GroupAccess.notGranted)
                  TextButton(
                    onPressed: () => showHealthPermissionSheet(
                      context,
                      ref,
                      HealthGroup.body,
                    ),
                    child: const Text('Allow Health Connect weight'),
                  ),
              ],
            ),
          );
        }
        final latest = list.last;
        final recent = list.reversed.take(5).toList();
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatTile(
                label: 'Latest',
                value: '${Fmt.oneDp(latest.value)} kg',
                sub: '${Fmt.dayMonth(latest.startAt)} · ${_sourceText(latest)}',
                icon: Icons.monitor_weight_outlined,
              ),
              const SizedBox(height: AppSpacing.md),
              if (list.length > 1)
                TrendLineChart(
                  points: [
                    for (final s in list)
                      (
                        at: s.startAt,
                        value: s.value,
                        manual: s.origin == HealthKeys.originManual,
                      ),
                  ],
                  color: AppColors.brand,
                  semanticLabel:
                      'Weight trend, ${list.length} entries over 90 days',
                ),
              const SizedBox(height: AppSpacing.sm),
              for (final s in recent)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${Fmt.dayMonth(s.startAt)}, ${Fmt.time(s.startAt)}',
                          style: t.bodySmall,
                        ),
                      ),
                      Text('${Fmt.oneDp(s.value)} kg', style: t.bodyMedium),
                      const SizedBox(width: AppSpacing.sm),
                      OriginChip(
                        s.origin == HealthKeys.originManual
                            ? 'Manual'
                            : sourceAppLabel(s.sourceApp),
                        color: s.origin == HealthKeys.originManual
                            ? AppColors.warning
                            : null,
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Day-to-day scale changes mostly reflect water, food and '
                'glycogen — not fat or muscle. Watch the trend over weeks. '
                'Hollow dots are manual entries.',
                style: t.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              SourceBadge(
                origin: latest.origin == HealthKeys.originManual
                    ? DataOrigin.manual
                    : DataOrigin.healthConnect,
                asOf: latest.syncedAt,
                now: now,
                staleAfter: const Duration(days: 7),
              ),
              const SizedBox(height: AppSpacing.sm),
              addButton,
            ],
          ),
        );
      },
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
          child: const SizedBox.shrink(),
        );
      }
      if (rows.isLoading) return const LoadingState();
      return const AppCard(
        child: EmptyState(
          icon: Icons.local_fire_department_outlined,
          title: 'No active calories in the last 7 days',
          compact: true,
        ),
      );
    }
    final byDate = {for (final r in list) r.localDate: r};
    final days = LocalDates.range(LocalDates.addDays(today, -6), today);
    final todayRow = byDate[today];
    final avg = list.fold<double>(0, (a, r) => a + r.value) / list.length;
    return AppCard(
      accent: AppColors.calories,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Today',
                  value: todayRow == null ? '–' : Fmt.kcal(todayRow.value),
                  icon: Icons.local_fire_department_outlined,
                  color: AppColors.calories,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Daily average',
                  value: Fmt.kcal(avg),
                  sub: '${list.length} days with data',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          DailyBarChart(
            values: [for (final d in days) (date: d, value: byDate[d]?.value)],
            color: AppColors.calories,
            height: 120,
            formatValue: Fmt.kcal,
            semanticLabel: 'Active calories for the last 7 days',
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
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
    final rows = ref.watch(
      recentSamplesProvider((HealthKeys.exerciseSession, 8)),
    );
    final list = rows.value ?? const <HealthSample>[];
    final t = Theme.of(context).textTheme;
    if (list.isEmpty) {
      if (access != GroupAccess.granted) {
        return _AccessGate(
          access: access,
          group: HealthGroup.activity,
          icon: Icons.fitness_center,
          child: const SizedBox.shrink(),
        );
      }
      if (rows.isLoading) return const LoadingState();
      return const AppCard(
        child: EmptyState(
          icon: Icons.fitness_center,
          title: 'No exercise sessions recorded recently',
          message: 'Workouts tracked in Samsung Health appear here after sync.',
          compact: true,
        ),
      );
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        children: [
          for (final s in list)
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
                final parts = <String>[
                  Fmt.duration((s.value * 60).round()),
                  if (distance != null && distance > 0) Fmt.km(distance),
                  sourceAppLabel(s.sourceApp),
                ];
                return ListTile(
                  leading: Icon(
                    normaliseCardioSport(type) == 'run'
                        ? Icons.directions_run
                        : normaliseCardioSport(type) == 'ride'
                        ? Icons.directions_bike
                        : normaliseCardioSport(type) != null
                        ? Icons.directions_walk
                        : Icons.fitness_center,
                    color: AppColors.running,
                  ),
                  title: Text(workoutLabel(type)),
                  subtitle: Text(
                    '${Fmt.weekdayDayMonth(s.startAt)}, '
                    '${Fmt.time(s.startAt)} · ${parts.join(' · ')}',
                  ),
                  trailing: Text(Fmt.ago(s.startAt, now), style: t.labelSmall),
                );
              },
            ),
        ],
      ),
    );
  }
}
