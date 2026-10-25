import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/train_providers.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';

class WorkoutDetailScreen extends ConsumerWidget {
  const WorkoutDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workoutLogsProvider);
    return async.when(
      loading: () =>
          const AppPage(title: 'Workout', children: [LoadingState()]),
      error: (e, _) => const AppPage(
        title: 'Workout',
        children: [ErrorState(message: 'Could not load this workout.')],
      ),
      data: (all) {
        final w = all.where((x) => x.id == id).firstOrNull;
        if (w == null) {
          return const AppPage(
            title: 'Workout',
            children: [
              EmptyState(
                icon: Icons.search_off,
                title: 'Workout not found',
                message: 'It may have been deleted in Hevy or on this device.',
              ),
            ],
          );
        }
        final prs = detectPrs(all).where((p) => p.workoutId == w.id).toList();
        final cmp = compareWithPrevious(w, all);
        return _WorkoutBody(workout: w, prs: prs, comparison: cmp);
      },
    );
  }
}

class _WorkoutBody extends StatelessWidget {
  const _WorkoutBody({
    required this.workout,
    required this.prs,
    required this.comparison,
  });
  final WorkoutLog workout;
  final List<PersonalRecord> prs;
  final SessionComparison? comparison;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final d = workout.duration;
    return AppPage(
      title: workout.title,
      subtitle:
          '${Fmt.weekdayDayMonth(workout.startAt)} · ${Fmt.time(workout.startAt)}'
          '${d != null && d.inMinutes > 0 ? ' · ${d.inMinutes} min' : ''}',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SourceBadge(origin: DataOrigin.fromKey(workout.source)),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          accent: AppColors.strength,
          child: Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Volume',
                  value: '${Fmt.integer(sessionVolume(workout))} kg',
                  sub: 'working sets only',
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Working sets',
                  value: '${workingSetCount(workout)}',
                ),
              ),
              Expanded(
                child: StatTile(label: 'PRs', value: '${prs.length}'),
              ),
            ],
          ),
        ),
        if (prs.isNotEmpty) ...[
          const SectionHeader('Personal records'),
          AppCard(
            child: Column(
              children: [
                for (final p in prs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.emoji_events,
                      color: AppColors.fat,
                    ),
                    title: Text(p.exerciseName),
                    subtitle: Text(prText(p)),
                  ),
              ],
            ),
          ),
        ],
        if (comparison != null) ...[
          SectionHeader(
            'Vs previous "${comparison!.previous.title}"',
            subtitle: Fmt.weekdayDayMonth(comparison!.previous.startAt),
          ),
          _ComparisonCard(comparison: comparison!),
        ],
        const SectionHeader('Exercises'),
        for (final e in workout.exercises) ...[
          _ExerciseTable(exercise: e),
          const SizedBox(height: AppSpacing.md),
        ],
        if (workout.notes != null) ...[
          const SectionHeader('Notes'),
          AppCard(child: Text(workout.notes!, style: t.bodyMedium)),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          'e1RM uses the Epley formula for sets of 1–12 reps; warm-up sets '
          'are excluded from volume, e1RM and PRs.',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

String prText(PersonalRecord p) => switch (p.type) {
  PrType.weight =>
    '${p.type.label}: ${Fmt.oneDp(p.value)} kg (prev ${Fmt.oneDp(p.previous)} kg)',
  PrType.e1Rm =>
    '${p.type.label}: ${Fmt.oneDp(p.value)} kg (prev ${Fmt.oneDp(p.previous)} kg)',
  PrType.volume =>
    '${p.type.label}: ${Fmt.integer(p.value)} kg (prev ${Fmt.integer(p.previous)} kg)',
  PrType.repsAtWeight =>
    '${p.value.toInt()} reps at ${Fmt.oneDp(p.weightKg ?? 0)} kg '
        '(prev ${p.previous.toInt()})',
};

class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.comparison});
  final SessionComparison comparison;

  String _signed(double v, {String unit = ''}) =>
      '${v >= 0 ? '+' : '−'}${Fmt.oneDp(v.abs())}$unit';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Color c(double v) => v > 0
        ? AppColors.success
        : v < 0
        ? AppColors.danger
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Volume ${_signed(comparison.volumeDelta, unit: ' kg')} · '
            'Sets ${_signed(comparison.setsDelta.toDouble())}',
            style: t.titleSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final e in comparison.exercises)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(e.name, style: t.bodyMedium)),
                  if (e.e1RmDelta != null)
                    Text(
                      'e1RM ${_signed(e.e1RmDelta!, unit: ' kg')}',
                      style: t.labelMedium?.copyWith(color: c(e.e1RmDelta!)),
                    )
                  else
                    Text(
                      e.previousVolume == 0 ? 'new' : '—',
                      style: t.labelMedium,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ExerciseTable extends StatelessWidget {
  const _ExerciseTable({required this.exercise});
  final ExerciseLog exercise;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final best = bestSet(exercise);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(exercise.name, style: t.titleSmall)),
              if (exercise.muscleGroup != null)
                Text(
                  prettyMuscle(exercise.muscleGroup!),
                  style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Table(
            columnWidths: const {
              0: FixedColumnWidth(40),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(),
            },
            children: [
              TableRow(
                children: [
                  for (final h in ['Set', 'kg', 'Reps', 'e1RM'])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        h,
                        style: t.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
              for (var i = 0; i < exercise.sets.length; i++)
                () {
                  final s = exercise.sets[i];
                  final e1 = setE1Rm(s);
                  final isBest = best != null && identical(best.set, s);
                  final style = t.bodyMedium?.copyWith(
                    fontWeight: isBest ? FontWeight.w700 : null,
                    color: s.isWarmup ? scheme.onSurfaceVariant : null,
                  );
                  return TableRow(
                    children: [
                      Text(
                        s.isWarmup
                            ? 'W'
                            : s.type == SetTypes.dropset
                            ? 'D'
                            : s.type == SetTypes.failure
                            ? 'F'
                            : '${i + 1}',
                        style: style,
                      ),
                      Text(
                        s.weightKg == null ? '—' : Fmt.oneDp(s.weightKg!),
                        style: style,
                      ),
                      Text(
                        s.reps?.toString() ??
                            (s.durationS != null
                                ? Fmt.duration(s.durationS!)
                                : '—'),
                        style: style,
                      ),
                      Text(e1 == null ? '—' : Fmt.oneDp(e1), style: style),
                    ],
                  );
                }(),
            ],
          ),
          if (exercise.notes != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(exercise.notes!, style: t.bodySmall),
          ],
        ],
      ),
    );
  }
}

String prettyMuscle(String raw) {
  final s = raw.replaceAll('_', ' ').trim();
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
