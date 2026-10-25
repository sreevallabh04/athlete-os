import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/train_providers.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';
import 'widgets/hud_kit.dart';

class WorkoutDetailScreen extends ConsumerWidget {
  const WorkoutDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workoutLogsProvider);
    return async.when(
      loading: () =>
          const AppPage(title: 'Workout', children: [ScanlineLoader(lines: 4)]),
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
    final hud = context.hud;
    final d = workout.duration;
    final prExercises = {for (final p in prs) exerciseKey(p.exerciseName)};
    return AppPage(
      title: workout.title,
      eyebrow:
          '${Fmt.weekdayDayMonth(workout.startAt).toUpperCase()} · '
          '${Fmt.time(workout.startAt).toUpperCase()}'
          '${d != null && d.inMinutes > 0 ? ' · ${d.inMinutes} MIN' : ''}',
      children: [
        AppCard(
          accent: AppColors.strength,
          brackets: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: HudReadout(
                      label: 'Volume',
                      value: Fmt.integer(sessionVolume(workout)),
                      unit: 'kg',
                      size: 30,
                    ),
                  ),
                  Expanded(
                    child: HudReadout(
                      label: 'Working sets',
                      value: '${workingSetCount(workout)}',
                      size: 30,
                    ),
                  ),
                  Expanded(
                    child: HudReadout(
                      label: 'PRs',
                      value: '${prs.length}',
                      size: 30,
                      color: prs.isEmpty ? null : AppColors.gold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  SourceBadge(origin: DataOrigin.fromKey(workout.source)),
                  const SizedBox(width: AppSpacing.sm),
                  Text('warm-ups excluded', style: hud.mono(size: 10)),
                ],
              ),
            ],
          ),
        ),
        if (prs.isNotEmpty) ...[
          const SectionHeader('Personal records', accent: AppColors.gold),
          _PrCard(prs: prs),
        ],
        if (comparison != null) ...[
          SectionHeader(
            'Vs previous',
            subtitle:
                '${comparison!.previous.title} · '
                '${Fmt.weekdayDayMonth(comparison!.previous.startAt)}',
          ),
          _ComparisonCard(comparison: comparison!),
        ],
        const SectionHeader('Exercises'),
        StaggeredList(
          gap: AppSpacing.md,
          children: [
            for (final (i, e) in workout.exercises.indexed)
              _ExerciseTable(
                index: i,
                exercise: e,
                pr: prExercises.contains(e.key),
              ),
          ],
        ),
        if (workout.notes != null) ...[
          const SectionHeader('Notes'),
          AppCard(child: Text(workout.notes!, style: t.bodyMedium)),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          'e1RM uses the Epley formula for sets of 1–12 reps; warm-up sets '
          'are excluded from volume, e1RM and PRs.',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
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

/// Gold PR slab; fires a celebration burst once when it appears.
class _PrCard extends StatefulWidget {
  const _PrCard({required this.prs});
  final List<PersonalRecord> prs;

  @override
  State<_PrCard> createState() => _PrCardState();
}

class _PrCardState extends State<_PrCard> with SingleTickerProviderStateMixin {
  final _burst = CelebrationController();

  // Ticker-based delay (cancelled on dispose, unlike a Timer) so the burst
  // lands after the card has cascaded in.
  late final AnimationController _delay = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..addStatusListener(_onDelay);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !AppMotion.reduced(context)) _delay.forward();
    });
  }

  void _onDelay(AnimationStatus s) {
    if (s != AnimationStatus.completed || !mounted) return;
    _burst.fire();
    Haptics.success();
  }

  @override
  void dispose() {
    _delay.dispose();
    _burst.dispose();
    super.dispose();
  }

  Map<String, List<PersonalRecord>> get _grouped {
    final out = <String, List<PersonalRecord>>{};
    for (final p in widget.prs) {
      out.putIfAbsent(p.exerciseName, () => []).add(p);
    }
    for (final l in out.values) {
      l.sort((a, b) => a.type.index.compareTo(b.type.index));
    }
    return out;
  }

  static String _short(PersonalRecord p) => switch (p.type) {
    PrType.e1Rm =>
      'E1RM ${Fmt.oneDp(p.value)} (${signed(p.value - p.previous)})',
    PrType.weight =>
      'TOP ${Fmt.oneDp(p.value)} KG (${signed(p.value - p.previous)})',
    PrType.repsAtWeight =>
      '${p.value.toInt()} REPS @ ${Fmt.oneDp(p.weightKg ?? 0)} KG',
    PrType.volume =>
      'VOL ${Fmt.integer(p.value)} (${signed(p.value - p.previous, digits: 0)})',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return CelebrationBurst(
      controller: _burst,
      color: AppColors.gold,
      spread: 0.8,
      child: AppCard(
        accent: AppColors.gold,
        glow: true,
        child: Column(
          children: [
            for (final (i, e) in _grouped.entries.indexed) ...[
              if (i > 0) const HudDivider(height: AppSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const GlowIcon(Icons.emoji_events, color: AppColors.gold),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.key, style: t.titleSmall),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.xs + 2,
                          runSpacing: AppSpacing.xs,
                          children: [
                            for (final p in e.value)
                              Semantics(
                                label: prText(p),
                                excludeSemantics: true,
                                child: HudTag(_short(p), color: AppColors.gold),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              'E1RM = estimated 1RM · TOP = heaviest set · VOL = exercise '
              'volume · change vs your previous best',
              style: hud.mono(size: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.comparison});
  final SessionComparison comparison;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    Color c(double v) => v > 0
        ? AppColors.success
        : v < 0
        ? AppColors.warning
        : hud.textMuted;
    IconData arrow(double v) => v > 0
        ? Icons.arrow_upward
        : v < 0
        ? Icons.arrow_downward
        : Icons.remove;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Volume change',
                  value: signed(comparison.volumeDelta, digits: 0),
                  unit: 'kg',
                  size: 24,
                  color: c(comparison.volumeDelta),
                ),
              ),
              Expanded(
                child: HudReadout(
                  label: 'Sets change',
                  value: signed(comparison.setsDelta, digits: 0),
                  size: 24,
                  color: c(comparison.setsDelta.toDouble()),
                ),
              ),
            ],
          ),
          const HudDivider(),
          for (final e in comparison.exercises)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.name,
                      style: t.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (e.e1RmDelta != null) ...[
                    Icon(arrow(e.e1RmDelta!), size: 14, color: c(e.e1RmDelta!)),
                    const SizedBox(width: 2),
                    Text(
                      'e1RM ${signed(e.e1RmDelta!, unit: ' kg')}',
                      style: hud
                          .mono(size: 11, color: c(e.e1RmDelta!))
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                  ] else
                    Text(
                      e.previousVolume == 0 ? 'NEW' : '—',
                      style: hud.mono(size: 11),
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
  const _ExerciseTable({
    required this.index,
    required this.exercise,
    required this.pr,
  });
  final int index;
  final ExerciseLog exercise;
  final bool pr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final best = bestSet(exercise);
    final head = hud.label(size: 10.5);
    return AppCard(
      accent: pr ? AppColors.gold : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HudBadge(
                text: (index + 1).toString().padLeft(2, '0'),
                color: pr ? AppColors.gold : AppColors.strength,
                size: 32,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(exercise.name, style: t.titleSmall),
                    Text(
                      exercise.muscleGroup == null
                          ? 'unmapped'
                          : prettyMuscle(exercise.muscleGroup!),
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
              if (pr) const HudTag('PR', color: AppColors.gold),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              SizedBox(width: 40, child: Text('SET', style: head)),
              Expanded(child: Text('KG', style: head)),
              Expanded(child: Text('REPS', style: head)),
              Expanded(
                child: Text('E1RM', style: head, textAlign: TextAlign.end),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < exercise.sets.length; i++)
            () {
              final s = exercise.sets[i];
              final e1 = setE1Rm(s);
              final isBest = best != null && identical(best.set, s);
              final color = s.isWarmup ? hud.textMuted : hud.text;
              final style = hud
                  .mono(size: 13, color: color)
                  .copyWith(
                    fontWeight: isBest ? FontWeight.w700 : FontWeight.w400,
                  );
              final typeLabel = s.isWarmup
                  ? 'W'
                  : s.type == SetTypes.dropset
                  ? 'D'
                  : s.type == SetTypes.failure
                  ? 'F'
                  : '${i + 1}';
              final typeColor = s.isWarmup
                  ? AppColors.warning
                  : s.type == SetTypes.failure
                  ? AppColors.danger
                  : s.type == SetTypes.dropset
                  ? AppColors.info
                  : hud.textMuted;
              return Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.xs),
                  color: isBest
                      ? AppColors.strength.withValues(alpha: 0.10)
                      : Colors.transparent,
                  border: isBest
                      ? const Border(
                          left: BorderSide(color: AppColors.strength, width: 2),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          typeLabel,
                          style: hud
                              .mono(size: 12, color: typeColor)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        s.weightKg == null ? '—' : Fmt.oneDp(s.weightKg!),
                        style: style,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        s.reps?.toString() ??
                            (s.durationS != null
                                ? Fmt.duration(s.durationS!)
                                : '—'),
                        style: style,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          e1 == null ? '—' : Fmt.oneDp(e1),
                          style: style.copyWith(
                            color: isBest ? AppColors.strength : null,
                          ),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }(),
          if (exercise.notes != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              exercise.notes!,
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
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
