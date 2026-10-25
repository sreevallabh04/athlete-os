import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/train_providers.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';
import 'widgets/charts.dart';
import 'widgets/sync_status.dart';
import 'workout_detail_screen.dart';

class StrengthScreen extends ConsumerWidget {
  const StrengthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workoutLogsProvider);
    final today = ref.watch(todayKeyProvider);
    return async.when(
      loading: () =>
          const AppPage(title: 'Strength', children: [LoadingState()]),
      error: (e, _) => const AppPage(
        title: 'Strength',
        children: [ErrorState(message: 'Could not load workouts.')],
      ),
      data: (workouts) {
        if (workouts.isEmpty) {
          return AppPage(
            title: 'Strength',
            children: [
              EmptyState(
                icon: Icons.fitness_center,
                title: 'No strength workouts yet',
                message:
                    'Connect Hevy, import a Hevy CSV or log a workout to see '
                    'e1RM trends, PRs and weekly volume.',
                actionLabel: 'Connect Hevy',
                onAction: () => context.push(AppPaths.integrations),
              ),
            ],
          );
        }
        return _StrengthBody(workouts: workouts, today: today);
      },
    );
  }
}

class _StrengthBody extends StatelessWidget {
  const _StrengthBody({required this.workouts, required this.today});
  final List<WorkoutLog> workouts;
  final String today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final weeks = weeklyStrength(workouts, todayKey: today, weeks: 8);
    final weekStart = LocalDates.weekStart(today);
    final thisWeek = workouts
        .where((w) => LocalDates.weekStart(w.localDate) == weekStart)
        .toList();
    final muscles = muscleGroupSets(thisWeek);
    final histories = exerciseHistories(workouts);
    final prs = detectPrs(workouts).reversed.take(5).toList();

    return AppPage(
      title: 'Strength',
      children: [
        const SectionHeader(
          'Weekly volume',
          subtitle: 'Σ weight × reps of working sets (kg), Monday weeks',
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SimpleBarChart(
                values: [for (final w in weeks) w.volumeKg],
                labels: [for (final w in weeks) weekLabel(w.weekStart)],
                color: AppColors.strength,
                semanticLabel:
                    'Weekly strength volume for the last 8 weeks. This week '
                    '${Fmt.integer(weeks.last.volumeKg)} kg.',
                valueLabel: (v) => '${Fmt.integer(v)} kg',
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Sessions per week: '
                '${weeks.map((w) => w.sessions).join(' · ')}',
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SectionHeader(
          'Sets per muscle group',
          subtitle: 'This week · mapped exercises only',
        ),
        _MuscleCard(muscles: muscles),
        const SectionHeader('Consistency', subtitle: 'Last 12 weeks'),
        AppCard(
          child: _Heatmap(workouts: workouts, today: today),
        ),
        if (prs.isNotEmpty) ...[
          const SectionHeader('Recent PRs'),
          AppCard(
            child: Column(
              children: [
                for (final p in prs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(
                      Icons.emoji_events,
                      color: AppColors.fat,
                    ),
                    title: Text(p.exerciseName),
                    subtitle: Text('${prText(p)} · ${Fmt.dayMonth(p.date)}'),
                    onTap: () => context.push('/workout/${p.workoutId}'),
                  ),
              ],
            ),
          ),
        ],
        const SectionHeader('Exercises', subtitle: 'Best e1RM per session'),
        for (final h in histories) ...[
          _ExerciseTile(history: h),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SectionHeader('Recent workouts'),
        for (final w in workouts.take(10))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(w.title),
            subtitle: Text(
              '${Fmt.weekdayDayMonth(w.startAt)} · '
              '${workingSetCount(w)} sets · '
              '${Fmt.integer(sessionVolume(w))} kg',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/workout/${w.id}'),
          ),
      ],
    );
  }
}

class _MuscleCard extends StatelessWidget {
  const _MuscleCard({required this.muscles});
  final MuscleGroupSets muscles;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final entries = muscles.setsByGroup.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxSets = entries.isEmpty ? 1 : entries.first.value;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entries.isEmpty)
            Text(
              'No mapped sets this week. Muscle groups come from Hevy '
              'exercise templates; manual and CSV exercises are unmapped.',
              style: t.bodyMedium,
            ),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: MetricBar(
                label: prettyMuscle(e.key),
                value: e.value.toDouble(),
                target: maxSets.toDouble(),
                color: AppColors.strength,
                formatter: (v) => v.round().toString(),
                unit: ' sets',
              ),
            ),
          if (muscles.unmappedSets > 0)
            Text(
              '${muscles.unmappedSets} set(s) from '
              '${muscles.unmappedExercises.length} unmapped exercise(s) not '
              'counted.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (entries.isNotEmpty && !muscles.sufficientForBalance)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Not enough mapped data to judge muscle balance.',
                style: t.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ),
        ],
      ),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.workouts, required this.today});
  final List<WorkoutLog> workouts;
  final String today;

  @override
  Widget build(BuildContext context) {
    final perDay = sessionsPerDay(workouts);
    final start = LocalDates.addDays(LocalDates.weekStart(today), -7 * 11);
    final scheme = Theme.of(context).colorScheme;
    final total = LocalDates.range(
      start,
      today,
    ).where((d) => (perDay[d] ?? 0) > 0).length;
    return Semantics(
      label: 'Training days heatmap: $total training days in 12 weeks',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var w = 0; w < 12; w++)
                Expanded(
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        () {
                          final key = LocalDates.addDays(start, w * 7 + d);
                          final n = perDay[key] ?? 0;
                          final future = key.compareTo(today) > 0;
                          return Container(
                            margin: const EdgeInsets.all(1.5),
                            height: 14,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              color: future
                                  ? Colors.transparent
                                  : n == 0
                                  ? scheme.surfaceContainerHighest
                                  : AppColors.strength.withValues(
                                      alpha: n > 1 ? 1 : 0.7,
                                    ),
                            ),
                          );
                        }(),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '$total training days · columns are weeks (Mon at top)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ExerciseTile extends StatelessWidget {
  const _ExerciseTile({required this.history});
  final ExerciseHistory history;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final prog = exerciseProgression(history);
    final e1s = history.sessions.map((s) => s.e1Rm).whereType<double>();
    final color = switch (prog.trend) {
      ProgressionTrend.improving => AppColors.success,
      ProgressionTrend.declining => AppColors.danger,
      ProgressionTrend.stable => AppColors.warning,
      ProgressionTrend.notEnoughData => Theme.of(
        context,
      ).colorScheme.onSurfaceVariant,
    };
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExerciseDetailScreen(exerciseKey: history.key),
        ),
      ),
      semanticLabel:
          '${history.name}, ${history.sessions.length} sessions, '
          'trend ${prog.trend.label}',
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(history.name, style: t.titleSmall),
                Text(
                  [
                    '${history.sessions.length} sessions',
                    if (history.bestE1Rm != null)
                      'best e1RM ${Fmt.oneDp(history.bestE1Rm!)} kg',
                  ].join(' · '),
                  style: t.bodySmall,
                ),
                Text(
                  prog.trend.label,
                  style: t.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
          Sparkline(
            values: e1s.toList().reversed.take(12).toList().reversed.toList(),
            color: AppColors.strength,
          ),
        ],
      ),
    );
  }
}

/// Per-exercise detail: e1RM chart, volume chart, PRs and history.
class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseKey});
  final String exerciseKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workouts = ref.watch(workoutLogsProvider).value ?? const [];
    final h = exerciseHistories(workouts)
        .where((x) => x.key == exerciseKey)
        .firstOrNull;
    if (h == null) {
      return const AppPage(
        title: 'Exercise',
        children: [EmptyState(icon: Icons.search_off, title: 'No data')],
      );
    }
    final t = Theme.of(context).textTheme;
    final prog = exerciseProgression(h);
    final withE1 = h.sessions.where((s) => s.e1Rm != null).toList();
    final prs = detectPrs(workouts)
        .where((p) => exerciseKey == exerciseKeyOf(p.exerciseName))
        .toList();
    return AppPage(
      title: h.name,
      subtitle: h.muscleGroup == null
          ? 'Muscle group unmapped'
          : prettyMuscle(h.muscleGroup!),
      children: [
        AppCard(
          accent: AppColors.strength,
          child: Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Best e1RM',
                  value: h.bestE1Rm == null
                      ? '—'
                      : '${Fmt.oneDp(h.bestE1Rm!)} kg',
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Trend',
                  value: prog.trend.label,
                  sub: prog.slopePctPerSession == null
                      ? 'needs ≥ $kMinProgressionSessions sessions'
                      : '${prog.slopePctPerSession! >= 0 ? '+' : ''}'
                            '${prog.slopePctPerSession!.toStringAsFixed(1)}%'
                            ' per session (last ${prog.sessions})',
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Estimated 1RM', subtitle: 'Epley, 1–12 reps'),
        AppCard(
          child: withE1.length < 2
              ? const Text('Log at least two sessions with 1–12 rep sets.')
              : TrendLineChart(
                  points: [
                    for (var i = 0; i < withE1.length; i++)
                      (i.toDouble(), withE1[i].e1Rm!),
                  ],
                  color: AppColors.strength,
                  semanticLabel: 'Estimated one rep max over time',
                  yLabel: (v) => v.toStringAsFixed(0),
                  xLabel: (v) {
                    final i = v.round();
                    return i >= 0 && i < withE1.length
                        ? Fmt.dayMonth(withE1[i].date)
                        : '';
                  },
                ),
        ),
        const SectionHeader('Volume per session'),
        AppCard(
          child: SimpleBarChart(
            values: [
              for (final s in h.sessions.reversed.take(12).toList().reversed)
                s.volumeKg,
            ],
            labels: [
              for (final s in h.sessions.reversed.take(12).toList().reversed)
                Fmt.dayMonth(s.date).split(' ').last,
            ],
            color: AppColors.strength,
            semanticLabel: 'Volume per session for ${h.name}',
            valueLabel: (v) => '${Fmt.integer(v)} kg',
          ),
        ),
        if (prs.isNotEmpty) ...[
          const SectionHeader('PRs'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in prs.reversed.take(10))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${Fmt.dayMonth(p.date)} · ${prText(p)}',
                      style: t.bodyMedium,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SectionHeader('History'),
        for (final s in h.sessions.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(Fmt.weekdayDayMonth(s.date)),
            subtitle: Text(
              [
                '${s.workingSets} sets',
                if (s.best?.set.weightKg != null)
                  'best ${Fmt.oneDp(s.best!.set.weightKg!)} kg × ${s.best!.set.reps ?? '-'}',
                if (s.e1Rm != null) 'e1RM ${Fmt.oneDp(s.e1Rm!)}',
              ].join(' · '),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/workout/${s.workoutId}'),
          ),
      ],
    );
  }
}

String exerciseKeyOf(String name) => exerciseKey(name);
