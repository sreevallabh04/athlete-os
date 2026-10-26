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
import 'log_workout_screen.dart';
import 'widgets/hud_kit.dart';
import 'widgets/prs.dart';
import 'widgets/sync_status.dart';
import 'workout_detail_screen.dart';

class StrengthScreen extends ConsumerWidget {
  const StrengthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workoutLogsProvider);
    final today = ref.watch(todayKeyProvider);
    return async.when(
      loading: () => const AppPage(
        title: 'Strength',
        children: [ScanlineLoader(height: 200, lines: 0)],
      ),
      error: (e, _) => const AppPage(
        title: 'Strength',
        children: [ErrorState(message: 'Could not load workouts.')],
      ),
      data: (workouts) {
        if (workouts.isEmpty) return const _StrengthEmpty();
        return _StrengthBody(workouts: workouts, today: today);
      },
    );
  }
}

class _StrengthEmpty extends StatelessWidget {
  const _StrengthEmpty();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppPage(
      title: 'Strength',
      eyebrow: 'E1RM · PRS · VOLUME',
      children: [
        AppCard(
          accent: AppColors.strength,
          brackets: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('WHAT YOU\'LL SEE HERE', style: hud.label(size: 11.5)),
              const SizedBox(height: AppSpacing.md),
              for (final (icon, title, body) in [
                (
                  Icons.show_chart,
                  'Estimated 1RM per lift',
                  'Interactive trend for every exercise (Epley, sets of 1 to 12 reps).',
                ),
                (
                  Icons.emoji_events_outlined,
                  'PR timeline',
                  'Heaviest sets, e1RM and rep records as they happen.',
                ),
                (
                  Icons.grid_view,
                  'Weekly sets per muscle',
                  'From Hevy templates; unmapped lifts are counted separately.',
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HudBadge(icon: icon, color: AppColors.strength, size: 34),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: t.titleSmall),
                            Text(
                              body,
                              style: t.bodySmall?.copyWith(
                                color: hud.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('No strength workouts yet', style: t.titleSmall),
              Text(
                'Connect Hevy, import a Hevy CSV or log your first session.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              HudButton(
                label: 'Connect Hevy',
                icon: Icons.hub_outlined,
                expand: true,
                onPressed: () => context.push(AppPaths.integrations),
              ),
              const SizedBox(height: AppSpacing.sm),
              HudButton.ghost(
                label: 'Log a workout',
                icon: Icons.edit_note,
                expand: true,
                onPressed: () => LogWorkoutScreen.open(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StrengthBody extends StatelessWidget {
  const _StrengthBody({required this.workouts, required this.today});
  final List<WorkoutLog> workouts;
  final String today;

  @override
  Widget build(BuildContext context) {
    final weeks = weeklyStrength(workouts, todayKey: today, weeks: 8);
    final weekStart = LocalDates.weekStart(today);
    final thisWeek = workouts
        .where((w) => LocalDates.weekStart(w.localDate) == weekStart)
        .toList();
    final muscles = muscleGroupSets(thisWeek);
    final histories = exerciseHistories(workouts);
    final prs = recentPrs(workouts, max: 6);

    return AppPage(
      title: 'Strength',
      eyebrow: '${workouts.length} SESSIONS · ${histories.length} EXERCISES',
      children: [
        _VolumeHero(weeks: weeks),
        const SectionHeader(
          'Leaderboard',
          subtitle: 'Tap a lift for its chart',
          accent: AppColors.strength,
        ),
        _Leaderboard(histories: histories),
        if (prs.isNotEmpty) ...[
          const SectionHeader('PR timeline', accent: AppColors.gold),
          AppCard(
            accent: AppColors.gold,
            child: _PrTimeline(prs: prs),
          ),
        ],
        const SectionHeader('Muscle sets', subtitle: 'This week · mapped only'),
        _MuscleCard(muscles: muscles),
        const SectionHeader('Consistency', subtitle: 'Last 12 weeks'),
        AppCard(
          child: _Heatmap(workouts: workouts, today: today),
        ),
        const SectionHeader('Recent workouts'),
        AppCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              for (final (i, w) in workouts.take(8).indexed) ...[
                if (i > 0) const HudDivider(height: 1),
                HudRow(
                  title: w.title,
                  subtitle:
                      '${Fmt.weekdayDayMonth(w.startAt)} · '
                      '${workingSetCount(w)} sets · '
                      '${Fmt.integer(sessionVolume(w))} kg',
                  onTap: () => context.push('/workout/${w.id}'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VolumeHero extends StatefulWidget {
  const _VolumeHero({required this.weeks});
  final List<WeekStrength> weeks;

  @override
  State<_VolumeHero> createState() => _VolumeHeroState();
}

class _VolumeHeroState extends State<_VolumeHero> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final weeks = widget.weeks;
    final i = _sel ?? weeks.length - 1;
    final w = weeks[i];
    final prev = i > 0 ? weeks[i - 1] : null;
    final delta = prev == null || prev.volumeKg <= 0
        ? null
        : (w.volumeKg - prev.volumeKg) / prev.volumeKg * 100;
    final isCurrent = i == weeks.length - 1;
    return AppCard(
      accent: AppColors.strength,
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Weekly volume', style: Theme.of(context).textTheme.titleSmall),
          Text(
            'Σ weight × reps of working sets · Monday weeks',
            style: hud.mono(size: 10),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: HudReadout(
                  label: isCurrent
                      ? 'This week'
                      : 'Week of ${weekLabel(w.weekStart)}',
                  value: Fmt.integer(w.volumeKg),
                  unit: 'kg',
                  size: 36,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (delta != null)
                    Text(
                      '${signed(delta, digits: 0)}% vs prev',
                      style: hud
                          .mono(
                            size: 11,
                            color: delta >= 0
                                ? AppColors.success
                                : AppColors.warning,
                          )
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                  Text(
                    '${w.sessions} sessions · ${w.workingSets} sets',
                    style: hud.mono(size: 10.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          HudBarChart(
            values: [for (final w in weeks) w.volumeKg],
            labels: [for (final w in weeks) weekLabel(w.weekStart)],
            color: AppColors.strength,
            highlight: i,
            height: 150,
            semanticLabel:
                'Weekly strength volume for the last 8 weeks. This week '
                '${Fmt.integer(weeks.last.volumeKg)} kg.',
            tooltip: (i, v) => '${Fmt.integer(v ?? 0)} kg',
            onSelect: (s) {
              if (s != null) setState(() => _sel = s);
            },
          ),
        ],
      ),
    );
  }
}

enum _Rank { gains, heaviest, recent }

/// e1RM change from the first to the latest session with an e1RM (%), or
/// null with fewer than two such sessions.
double? _gainPct(ExerciseHistory h) {
  final e = h.sessions.map((s) => s.e1Rm).whereType<double>().toList();
  if (e.length < 2 || e.first <= 0) return null;
  return (e.last - e.first) / e.first * 100;
}

class _Leaderboard extends StatefulWidget {
  const _Leaderboard({required this.histories});
  final List<ExerciseHistory> histories;

  @override
  State<_Leaderboard> createState() => _LeaderboardState();
}

class _LeaderboardState extends State<_Leaderboard> {
  _Rank _rank = _Rank.gains;
  bool _all = false;
  static const _top = 6;

  List<ExerciseHistory> get _sorted {
    final list = [...widget.histories];
    int byNullable(double? a, double? b) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return b.compareTo(a);
    }

    switch (_rank) {
      case _Rank.gains:
        list.sort((a, b) => byNullable(_gainPct(a), _gainPct(b)));
      case _Rank.heaviest:
        list.sort((a, b) => byNullable(a.bestE1Rm, b.bestE1Rm));
      case _Rank.recent:
        break; // exerciseHistories is already most-recent first.
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;
    final shown = _all ? sorted : sorted.take(_top).toList();
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedHud<_Rank>(
            segments: const [
              HudSegment(value: _Rank.gains, label: 'Gains'),
              HudSegment(value: _Rank.heaviest, label: 'Heaviest'),
              HudSegment(value: _Rank.recent, label: 'Recent'),
            ],
            value: _rank,
            onChanged: (v) => setState(() => _rank = v),
          ),
          const SizedBox(height: AppSpacing.xs),
          AnimatedSize(
            duration: AppMotion.medium,
            curve: AppMotion.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: StaggeredList(
              key: ValueKey(_rank),
              gap: 0,
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const HudDivider(height: 1),
                  _LeaderRow(
                    rank: i + 1,
                    history: shown[i],
                    showGain: _rank == _Rank.gains,
                  ),
                ],
              ],
            ),
          ),
          if (sorted.length > _top)
            HudButton.ghost(
              label: _all ? 'Show top $_top' : 'Show all ${sorted.length}',
              icon: _all ? Icons.expand_less : Icons.expand_more,
              compact: true,
              onPressed: () => setState(() => _all = !_all),
            ),
        ],
      ),
    );
  }
}

Color trendColor(BuildContext context, ProgressionTrend t) => switch (t) {
  ProgressionTrend.improving => AppColors.success,
  ProgressionTrend.declining => AppColors.danger,
  ProgressionTrend.stable => AppColors.warning,
  ProgressionTrend.notEnoughData => context.hud.textMuted,
};

class _LeaderRow extends StatelessWidget {
  const _LeaderRow({
    required this.rank,
    required this.history,
    this.showGain = false,
  });
  final int rank;
  final ExerciseHistory history;
  final bool showGain;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final prog = exerciseProgression(history);
    final e1s = history.sessions.map((s) => s.e1Rm).whereType<double>();
    final spark = e1s.length > 12
        ? e1s.toList().sublist(e1s.length - 12)
        : e1s.toList();
    final c = trendColor(context, prog.trend);
    final best = history.bestE1Rm;
    return Semantics(
      button: true,
      label:
          '${history.name}, best e1RM '
          '${best == null ? 'none' : '${Fmt.oneDp(best)} kg'}, '
          'trend ${prog.trend.label}',
      container: true,
      child: PressableScale(
        pressedScale: 0.975,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ExerciseDetailScreen(exerciseKey: history.key),
          ),
        ),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    rank.toString().padLeft(2, '0'),
                    style: hud.mono(
                      size: 12,
                      color: rank <= 3 ? AppColors.gold : hud.textMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Hero(
                        tag: 'exercise-${history.key}',
                        child: Material(
                          type: MaterialType.transparency,
                          child: Text(
                            history.name,
                            style: t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            prog.trend.label,
                            style: t.labelSmall?.copyWith(color: c),
                          ),
                          Flexible(
                            child: Text(
                              ' · ${history.sessions.length} sessions',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.labelSmall?.copyWith(
                                color: hud.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 64,
                  child: spark.length >= 2
                      ? HudSparkline(
                          values: spark,
                          color: AppColors.strength,
                          height: 26,
                          strokeWidth: 1.6,
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 66,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (showGain && _gainPct(history) != null) ...[
                        Text(
                          '${signed(_gainPct(history)!)}%',
                          style: hud.number(
                            size: 19,
                            color: _gainPct(history)! >= 0
                                ? AppColors.success
                                : AppColors.warning,
                          ),
                        ),
                        Text(
                          'e1RM ${Fmt.oneDp(best!)}',
                          style: hud.mono(size: 9.5),
                        ),
                      ] else ...[
                        Text(
                          best == null ? '—' : Fmt.oneDp(best),
                          style: hud.number(size: 20),
                        ),
                        Text(
                          best == null ? 'no e1RM' : 'kg e1RM',
                          style: hud.mono(size: 9.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrTimeline extends StatelessWidget {
  const _PrTimeline({required this.prs});
  final List<PersonalRecord> prs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Column(
      children: [
        for (var i = 0; i < prs.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 22,
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 5),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == 0
                              ? AppColors.gold
                              : AppColors.gold.withValues(alpha: 0.25),
                          border: Border.all(color: AppColors.gold),
                          boxShadow: i == 0
                              ? AppGlows.soft(
                                  AppColors.gold,
                                  strength: hud.glowStrength,
                                )
                              : null,
                        ),
                      ),
                      if (i < prs.length - 1)
                        Expanded(
                          child: Container(
                            width: 1,
                            color: AppColors.gold.withValues(alpha: 0.25),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: PressableScale(
                    onTap: () => context.push('/workout/${prs[i].workoutId}'),
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: i < prs.length - 1 ? AppSpacing.md : 0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Fmt.weekdayDayMonth(prs[i].date).toUpperCase(),
                            style: hud.mono(size: 10),
                          ),
                          Text(prs[i].exerciseName, style: t.titleSmall),
                          Text(
                            prText(prs[i]),
                            style: t.bodySmall?.copyWith(color: hud.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
    final hud = context.hud;
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
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
              child: Semantics(
                label: '${prettyMuscle(e.key)}: ${e.value} sets',
                excludeSemantics: true,
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        prettyMuscle(e.key),
                        style: t.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: 6,
                        child: HudTrack(
                          fraction: e.value / maxSets,
                          color: AppColors.strength,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${e.value}',
                        textAlign: TextAlign.end,
                        style: hud.number(size: 17),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (entries.isNotEmpty) const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              HudTag('${muscles.mappedSets} MAPPED SETS', color: hud.accentInk),
              if (muscles.unmappedSets > 0)
                HudTag(
                  '${muscles.unmappedSets} UNMAPPED · '
                  '${muscles.unmappedExercises.length} EXERCISE'
                  '${muscles.unmappedExercises.length == 1 ? '' : 'S'}',
                  color: AppColors.warning,
                ),
            ],
          ),
          if (entries.isNotEmpty && !muscles.sufficientForBalance)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
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

/// GitHub-style training heatmap, HUD edition: 12 week columns × 7 days,
/// trained days glow, today is outlined.
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.workouts, required this.today});
  final List<WorkoutLog> workouts;
  final String today;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final perDay = sessionsPerDay(workouts);
    final start = LocalDates.addDays(LocalDates.weekStart(today), -7 * 11);
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
              Column(
                children: [
                  for (var d = 0; d < 7; d++)
                    SizedBox(
                      height: 17,
                      width: 14,
                      child: Text(
                        d.isEven ? weekdayLetters[d] : '',
                        style: hud.mono(size: 9),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              for (var w = 0; w < 12; w++)
                Expanded(
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        () {
                          final key = LocalDates.addDays(start, w * 7 + d);
                          final n = perDay[key] ?? 0;
                          final future = key.compareTo(today) > 0;
                          final isToday = key == today;
                          return Container(
                            margin: const EdgeInsets.all(1.5),
                            height: 14,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              color: future
                                  ? Colors.transparent
                                  : n == 0
                                  ? hud.hairline.withValues(alpha: 0.07)
                                  : AppColors.strength.withValues(
                                      alpha: n > 1 ? 1 : 0.78,
                                    ),
                              border: isToday
                                  ? Border.all(color: hud.accent, width: 1.2)
                                  : null,
                              boxShadow: n > 0 && !future
                                  ? [
                                      BoxShadow(
                                        color: AppColors.strength.withValues(
                                          alpha: 0.45 * hud.glowStrength,
                                        ),
                                        blurRadius: 5,
                                      ),
                                    ]
                                  : null,
                            ),
                          );
                        }(),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$total training days · columns are weeks',
                  style: hud.mono(size: 10),
                ),
              ),
              Text('LESS ', style: hud.mono(size: 9)),
              for (final a in [0.07, 0.78, 1.0])
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: a < 0.1
                        ? hud.hairline.withValues(alpha: a)
                        : AppColors.strength.withValues(alpha: a),
                  ),
                ),
              Text(' MORE', style: hud.mono(size: 9)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Per-exercise detail: interactive e1RM chart (scrub for any session),
/// volume per session, PRs and full history.
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
        children: [
          EmptyState(
            icon: Icons.search_off,
            title: 'No data',
            message: 'This exercise has no logged working sets.',
          ),
        ],
      );
    }
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final prog = exerciseProgression(h);
    final prs = detectPrs(workouts)
        .where((p) => exerciseKey == exerciseKeyOf(p.exerciseName))
        .toList();
    final recent = h.sessions.length > 12
        ? h.sessions.sublist(h.sessions.length - 12)
        : h.sessions;
    return AppPage(
      title: 'Exercise',
      eyebrow:
          (h.muscleGroup == null
                  ? 'MUSCLE GROUP UNMAPPED'
                  : prettyMuscle(h.muscleGroup!))
              .toUpperCase(),
      children: [
        Hero(
          tag: 'exercise-${h.key}',
          child: Material(
            type: MaterialType.transparency,
            child: Text(h.name, style: t.headlineSmall),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _E1rmCard(history: h, prog: prog, prs: prs),
        const SectionHeader('Volume per session'),
        AppCard(
          child: HudBarChart(
            values: [for (final s in recent) s.volumeKg],
            labels: [
              for (var i = 0; i < recent.length; i++)
                i.isEven || recent.length <= 6
                    ? '${recent[i].date.day}/${recent[i].date.month}'
                    : '',
            ],
            color: AppColors.strength,
            highlight: recent.length - 1,
            semanticLabel: 'Volume per session for ${h.name}',
            tooltip: (i, v) =>
                '${Fmt.dayMonth(recent[i].date)}\n${Fmt.integer(v ?? 0)} kg',
          ),
        ),
        if (prs.isNotEmpty) ...[
          const SectionHeader('PRs', accent: AppColors.gold),
          AppCard(
            accent: AppColors.gold,
            child: _PrTimeline(prs: prs.reversed.take(8).toList()),
          ),
        ],
        const SectionHeader('History'),
        AppCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            children: [
              for (final (i, s) in h.sessions.reversed.indexed) ...[
                if (i > 0) const HudDivider(height: 1),
                HudRow(
                  title: Fmt.weekdayDayMonth(s.date),
                  subtitle: [
                    '${s.workingSets} sets',
                    if (s.best?.set.weightKg != null)
                      'best ${Fmt.oneDp(s.best!.set.weightKg!)} kg × '
                          '${s.best!.set.reps ?? '-'}',
                  ].join(' · '),
                  trailing: s.e1Rm == null
                      ? null
                      : Text(Fmt.oneDp(s.e1Rm!), style: hud.number(size: 18)),
                  onTap: () => context.push('/workout/${s.workoutId}'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _E1rmCard extends StatefulWidget {
  const _E1rmCard({
    required this.history,
    required this.prog,
    required this.prs,
  });
  final ExerciseHistory history;
  final ProgressionResult prog;
  final List<PersonalRecord> prs;

  @override
  State<_E1rmCard> createState() => _E1rmCardState();
}

class _E1rmCardState extends State<_E1rmCard> {
  int? _scrub;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final h = widget.history;
    final prog = widget.prog;
    final withE1 = h.sessions.where((s) => s.e1Rm != null).toList();
    final prWorkouts = {
      for (final p in widget.prs)
        if (p.type == PrType.e1Rm) p.workoutId,
    };
    final i = _scrub ?? withE1.length - 1;
    final point = withE1.isEmpty ? null : withE1[i];
    final slope = prog.slopePctPerSession;
    return AppCard(
      accent: AppColors.strength,
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: HudReadout(
                  label: _scrub == null
                      ? 'Best e1RM'
                      : Fmt.weekdayDayMonth(point!.date),
                  value: _scrub == null
                      ? (h.bestE1Rm == null ? '—' : Fmt.oneDp(h.bestE1Rm!))
                      : Fmt.oneDp(point!.e1Rm!),
                  unit: 'kg',
                  size: 38,
                  caption: _scrub == null
                      ? 'Epley, 1–12 reps · drag the chart'
                      : 'best ${Fmt.oneDp(point!.best!.set.weightKg ?? 0)} kg '
                            '× ${point.best!.set.reps ?? '-'}',
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    prog.trend.label.toUpperCase(),
                    style: hud.label(
                      size: 11,
                      color: trendColor(context, prog.trend),
                    ),
                  ),
                  Text(
                    slope == null
                        ? 'needs ≥ $kMinProgressionSessions sessions'
                        : '${signed(slope)}% / session',
                    style: hud.mono(size: 10.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (withE1.length < 2)
            Text(
              'Log at least two sessions with 1–12 rep sets to see a trend.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: hud.textMuted),
            )
          else
            HudLineChart(
              values: [for (final s in withE1) s.e1Rm!],
              color: AppColors.strength,
              semanticLabel: 'Estimated one rep max over time',
              format: (v) => v.toStringAsFixed(0),
              xLabel: (i) => '${withE1[i].date.day}/${withE1[i].date.month}',
              tooltip: (i) =>
                  '${Fmt.dayMonth(withE1[i].date)} · '
                  '${Fmt.oneDp(withE1[i].e1Rm!)} kg',
              gold: {
                for (var j = 0; j < withE1.length; j++)
                  if (prWorkouts.contains(withE1[j].workoutId)) j,
              },
              onScrub: (s) => setState(() => _scrub = s),
            ),
          if (prWorkouts.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.gold,
                  ),
                ),
                const SizedBox(width: 6),
                Text('e1RM PR', style: hud.mono(size: 10)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String exerciseKeyOf(String name) => exerciseKey(name);
