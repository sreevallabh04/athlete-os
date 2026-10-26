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
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../health/application/health_providers.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/training_program.dart';
import '../../onboarding/presentation/program_screen.dart';
import '../application/train_providers.dart';
import '../domain/running_analytics.dart';
import '../domain/running_models.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';
import 'log_workout_screen.dart';
import 'widgets/hud_kit.dart';
import 'widgets/prs.dart';
import 'widgets/strava_branding.dart';
import 'widgets/sync_status.dart';
import 'widgets/week_plan.dart';

/// Train tab: the training command center.
///
/// Week HUD (planned days vs real logs, volume gauge, km) → today's session
/// with a one-tap start → recent PRs → quick links → honest sync status.
/// On first run the program and targets are already alive; missing data is
/// a compact setup card, never a fake number.
class TrainScreen extends ConsumerWidget {
  const TrainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(workoutLogsProvider);
    final cardioAsync = ref.watch(cardioActivitiesProvider);
    final program = ref.watch(activeProgramProvider).value;
    final session = ref.watch(todaysPlannedSessionProvider).value;
    final hevy = ref.watch(integrationStatusProvider(Providers.hevy)).value;
    final strava = ref.watch(integrationStatusProvider(Providers.strava)).value;
    final now = ref.watch(clockProvider).now();
    final today = ref.watch(todayKeyProvider);
    final controller = ref.read(syncControllerProvider.notifier);

    Future<void> refresh() async {
      if (isConnected(hevy)) await controller.syncHevy();
      if (Env.hasStrava && isConnected(strava)) await controller.syncStrava();
    }

    final week = program?.weekNumber(today);
    final eyebrow = [
      if (week != null) 'WEEK $week',
      Fmt.weekdayDayMonth(now).toUpperCase(),
      Fmt.time(now).toUpperCase(),
    ].join(' · ');

    final children = <Widget>[];
    if (workoutsAsync.isLoading || cardioAsync.isLoading) {
      children.add(const ScanlineLoader(height: 220, lines: 0));
    } else if (workoutsAsync.hasError || cardioAsync.hasError) {
      children.add(
        const ErrorState(
          message: 'Could not load training data from this device.',
        ),
      );
    } else {
      final workouts = workoutsAsync.value ?? const <WorkoutLog>[];
      final cardio = cardioAsync.value ?? const <RunActivity>[];
      final empty = workouts.isEmpty && cardio.isEmpty;

      if (program != null) {
        children.add(
          _WeekHud(
            program: program,
            today: today,
            workouts: workouts,
            cardio: cardio,
          ),
        );
      }
      children.add(const SizedBox(height: AppSpacing.md));
      if (program == null) {
        children.add(const _CalibrateCard());
      } else if (session != null) {
        children.add(
          _TodaySessionCard(
            session: session,
            workouts: workouts,
            cardio: cardio,
            now: now,
          ),
        );
      }
      if (empty) {
        children.add(const SizedBox(height: AppSpacing.md));
        children.add(const _FirstRunCard());
      } else {
        final prs = recentPrs(workouts);
        children.add(
          SectionHeader(
            'Recent PRs',
            subtitle: prs.isEmpty
                ? 'Needs a baseline first'
                : 'e1RM · top sets',
            accent: AppColors.gold,
            action: 'All',
            onAction: () => context.push(AppPaths.strength),
          ),
        );
        children.add(_PrTicker(prs: prs, now: now));
        children.add(const SectionHeader('Latest'));
        children.add(
          _LatestCard(
            workout: workouts.firstOrNull,
            run: cardio.where((a) => a.isRun).firstOrNull,
          ),
        );
      }
      children.add(const SectionHeader('Explore'));
      children.add(
        _QuickGrid(workouts: workouts, cardio: cardio, today: today),
      );
      children.add(
        const SectionHeader(
          'Data links',
          subtitle: 'Read-only · tap for status',
        ),
      );
      children.add(_SyncChips(now: now));
      if (cardio.any((a) => a.isStrava)) {
        children.add(const SizedBox(height: AppSpacing.md));
        children.add(const PoweredByStrava());
      }
    }

    return AppPage(
      title: 'Train',
      eyebrow: eyebrow,
      onRefresh: refresh,
      actions: [
        IconButton(
          tooltip: 'Add training',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => _showAddSheet(context, ref, session),
        ),
      ],
      children: children,
    );
  }
}

void _showAddSheet(
  BuildContext context,
  WidgetRef ref,
  PlannedSession? session,
) {
  showHudBottomSheet<void>(
    context,
    title: 'Add training',
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (session != null && session.day.exercises.isNotEmpty)
          HudRow(
            leading: HudBadge(
              icon: Icons.play_arrow_rounded,
              color: sessionColor(session.day.kind),
            ),
            title: 'Start ${session.day.title}',
            subtitle: 'Pre-filled from today\'s program',
            onTap: () {
              Navigator.pop(ctx);
              _startSession(context, ref, session);
            },
          ),
        HudRow(
          leading: const HudBadge(
            icon: Icons.edit_note,
            color: AppColors.strength,
          ),
          title: 'Log workout manually',
          subtitle: 'Sets, reps, rest timer',
          onTap: () {
            Navigator.pop(ctx);
            LogWorkoutScreen.open(context);
          },
        ),
        HudRow(
          leading: const HudBadge(
            icon: Icons.upload_file,
            color: AppColors.info,
          ),
          title: 'Import Hevy CSV',
          subtitle: 'Works without Hevy Pro',
          onTap: () {
            Navigator.pop(ctx);
            showCsvImportDialog(context, ref);
          },
        ),
        HudRow(
          leading: const HudBadge(
            icon: Icons.hub_outlined,
            color: AppColors.info,
          ),
          title: 'Connect apps',
          subtitle: 'Hevy, Strava, Health Connect',
          onTap: () {
            Navigator.pop(ctx);
            context.push(AppPaths.integrations);
          },
        ),
      ],
    ),
  );
}

void _startSession(BuildContext context, WidgetRef ref, PlannedSession s) {
  final day = s.lighter ?? s.day;
  LogWorkoutScreen.open(
    context,
    initial: workoutDraftFor(day, ref.read(clockProvider).now()),
    restSeconds: [for (final e in day.exercises) e.restSeconds],
  );
}

// ---------------------------------------------------------------------------
// Week HUD
// ---------------------------------------------------------------------------

class _WeekHud extends StatelessWidget {
  const _WeekHud({
    required this.program,
    required this.today,
    required this.workouts,
    required this.cardio,
  });

  final TrainingProgram program;
  final String today;
  final List<WorkoutLog> workouts;
  final List<RunActivity> cardio;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final days = planWeek(
      program: program,
      today: today,
      workouts: workouts,
      activities: cardio,
    );
    final weekStart = LocalDates.weekStart(today);
    final lastWeekStart = LocalDates.addDays(weekStart, -7);
    double volumeOf(String ws) => workouts
        .where((w) => LocalDates.weekStart(w.localDate) == ws)
        .fold(0.0, (a, w) => a + sessionVolume(w));
    final vol = volumeOf(weekStart);
    final lastVol = volumeOf(lastWeekStart);
    final runs = cardio
        .where((a) => a.isRun && LocalDates.weekStart(a.localDate) == weekStart)
        .toList();
    final km = runs.fold(0.0, (a, r) => a + (r.distanceM ?? 0)) / 1000;
    final liftsPlanned = days.where((d) => d.day.isLift).length;
    final runsPlanned = days.length - liftsPlanned;
    final liftsDone = days.where((d) => d.day.isLift && d.done).length;
    final runsDone = days.where((d) => !d.day.isLift && d.done).length;
    final ref = lastVol > 0 ? lastVol : vol;
    final week = program.weekNumber(today);
    final deload = program.isDeloadWeek(week);
    return AppCard(
      brackets: true,
      glow: true,
      semanticLabel:
          'This week: $liftsDone of $liftsPlanned lifts, $runsDone of '
          '$runsPlanned runs, ${Fmt.integer(vol)} kg volume, '
          '${km.toStringAsFixed(1)} km',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'THIS WEEK',
                style: hud.label(size: 12, color: hud.accentInk),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'from ${Fmt.dayMonth(LocalDates.parse(weekStart))}',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ),
              if (deload)
                const HudChip(
                  label: 'Deload',
                  color: AppColors.warning,
                  dot: true,
                )
              else
                HudTag(
                  'WK ${(week - 1) % program.deloadEvery + 1}/${program.deloadEvery}',
                  color: hud.accentInk,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          WeekNodes(
            days: days,
            today: today,
            onSelect: (_) => context.push('${AppPaths.program}?hero=train'),
          ),
          const HudDivider(height: AppSpacing.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                children: [
                  ArcGauge(
                    value: ref <= 0 ? 0 : vol / ref,
                    valueText: vol >= 10000
                        ? '${(vol / 1000).toStringAsFixed(1)}k'
                        : Fmt.integer(vol),
                    label: 'KG VOLUME',
                    color: AppColors.strength,
                    width: 140,
                    stroke: 8,
                    semanticLabel: 'Lifting volume this week',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lastVol > 0
                        ? '${(vol / lastVol * 100).round()}% of last week'
                        : vol > 0
                        ? 'First tracked week'
                        : 'No volume yet',
                    style: hud.mono(size: 10),
                  ),
                ],
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MiniStat(
                      label: 'Lifts',
                      value: '$liftsDone/$liftsPlanned',
                      fraction: liftsPlanned == 0
                          ? 0
                          : liftsDone / liftsPlanned,
                      color: AppColors.strength,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _MiniStat(
                      label: 'Runs',
                      value: '$runsDone/$runsPlanned',
                      fraction: runsPlanned == 0 ? 0 : runsDone / runsPlanned,
                      color: AppColors.running,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _MiniStat(
                      label: 'Run km',
                      value: km.toStringAsFixed(1),
                      color: AppColors.running,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    this.fraction,
  });
  final String label;
  final String value;
  final Color color;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(label.toUpperCase(), style: hud.label(size: 11)),
            ),
            AnimatedTicker(value, style: hud.number(size: 20)),
          ],
        ),
        if (fraction != null) ...[
          const SizedBox(height: 4),
          SizedBox(
            height: 3,
            child: HudTrack(fraction: fraction!, color: color),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Today's session
// ---------------------------------------------------------------------------

class _TodaySessionCard extends ConsumerWidget {
  const _TodaySessionCard({
    required this.session,
    required this.workouts,
    required this.cardio,
    required this.now,
  });

  final PlannedSession session;
  final List<WorkoutLog> workouts;
  final List<RunActivity> cardio;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final day = session.day;
    final color = sessionColor(day.kind);
    final start = ref.watch(calibrationProvider).value?.trainingStart;
    final isRun = day.kind == SessionKind.run;
    final doneWorkout = isRun
        ? null
        : workouts.where((w) => w.localDate == session.date).firstOrNull;
    final doneRun = isRun
        ? cardio
              .where((a) => a.isRun && a.localDate == session.date)
              .firstOrNull
        : null;
    final done = doneWorkout != null || doneRun != null;
    final lighter = session.lighter;
    void openProgram() => context.push('${AppPaths.program}?hero=train');

    final status = done
        ? 'DONE'
        : start == null
        ? 'TODAY'
        : 'TODAY · ${(start ~/ 60).toString().padLeft(2, '0')}:'
              '${(start % 60).toString().padLeft(2, '0')}';
    final run = day.run;
    final lines = run != null
        ? [
            '${run.minutes} min · ${formatPaceRange(run.paceMinS, run.paceMaxS)}',
            run.description,
          ]
        : [
            for (final e in day.exercises.take(3))
              '${e.sets} × ${e.repRange}  ${e.name}',
            if (day.exercises.length > 3) '+${day.exercises.length - 3} more',
          ];

    final card = AppCard(
      accent: color,
      onTap: openProgram,
      semanticLabel: 'Today: ${day.title}${done ? ', done' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              HudBadge(icon: sessionIcon(day.kind), color: color, size: 46),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          status,
                          style: hud.label(
                            size: 11.5,
                            color: done ? AppColors.success : color,
                          ),
                        ),
                        if (!done) ...[
                          const SizedBox(width: 6),
                          HudDot(color: color, size: 5, pulse: true),
                        ],
                      ],
                    ),
                    Text(
                      day.title,
                      style: t.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      day.focus,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: hud.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs + 2,
            runSpacing: AppSpacing.xs,
            children: [
              if (run == null) ...[
                HudTag('${day.exercises.length} EXERCISES'),
                HudTag('${day.totalSets} SETS'),
              ],
              HudTag('~${day.minutes} MIN'),
              if (session.isDeload)
                const HudTag('DELOAD −40%', color: AppColors.warning),
              if (lighter != null && !done)
                const HudTag('READINESS LOW', color: AppColors.warning),
              for (final w in session.warnings)
                HudTag(
                  w.substitute == null ? 'CAUTION' : 'SWAP: ${w.substitute}',
                  color: AppColors.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (done && doneWorkout != null)
            Text(
              '${doneWorkout.duration == null ? '' : '${doneWorkout.duration!.inMinutes} min · '}'
              '${workingSetCount(doneWorkout)} sets · '
              '${Fmt.integer(sessionVolume(doneWorkout))} kg logged',
              style: t.bodyMedium,
            )
          else if (done && doneRun != null)
            Text(
              [
                if (doneRun.distanceM != null) Fmt.km(doneRun.distanceM!),
                if (doneRun.paceSPerKm != null) Fmt.pace(doneRun.paceSPerKm!),
              ].join(' · '),
              style: t.bodyMedium,
            )
          else
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  l,
                  style: hud.mono(size: 11.5, color: hud.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          const SizedBox(height: AppSpacing.lg),
          if (done)
            HudButton.secondary(
              label: doneWorkout != null ? 'View workout' : 'View run',
              icon: Icons.check_circle_outline,
              expand: true,
              onPressed: () => context.push(
                doneWorkout != null
                    ? '/workout/${doneWorkout.id}'
                    : '/running/activity/${doneRun!.id}',
              ),
            )
          else if (run == null)
            HudButton(
              label: lighter != null
                  ? 'Start lighter session'
                  : 'Start session',
              icon: Icons.play_arrow_rounded,
              expand: true,
              onPressed: () => _startSession(context, ref, session),
            )
          else
            HudButton.secondary(
              label: 'Open run plan',
              icon: Icons.route_outlined,
              expand: true,
              onPressed: openProgram,
            ),
        ],
      ),
    );
    return Hero(tag: 'train-${session.heroTag}', child: card);
  }
}

class _CalibrateCard extends StatelessWidget {
  const _CalibrateCard();

  @override
  Widget build(BuildContext context) => AppCard(
    accent: AppColors.cyan,
    brackets: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HudRow(
          leading: HudBadge(icon: Icons.auto_awesome, color: AppColors.cyan),
          title: 'Generate your program',
          subtitle:
              'Calibration builds your 5 lift + 2 run week, pace zones '
              'and deloads.',
          chevron: false,
        ),
        const SizedBox(height: AppSpacing.md),
        HudButton(
          label: 'Calibrate',
          icon: Icons.auto_awesome,
          expand: true,
          onPressed: () => context.push(AppPaths.onboarding),
        ),
      ],
    ),
  );
}

/// First run: no workouts or runs yet. Compact, actionable.
class _FirstRunCard extends ConsumerWidget {
  const _FirstRunCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      semanticLabel: 'No training data yet',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              HudBadge(icon: Icons.input, color: hud.accent, size: 36),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('No training data yet', style: t.titleSmall),
                    Text(
                      'Bring in your history once; trends, PRs and the week '
                      'HUD fill in automatically.',
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          HudButton.secondary(
            label: 'Connect apps',
            icon: Icons.hub_outlined,
            expand: true,
            onPressed: () => context.push(AppPaths.integrations),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: HudButton.ghost(
                  label: 'Log manually',
                  icon: Icons.edit_note,
                  compact: true,
                  onPressed: () => LogWorkoutScreen.open(context),
                ),
              ),
              Expanded(
                child: HudButton.ghost(
                  label: 'Import CSV',
                  icon: Icons.upload_file,
                  compact: true,
                  onPressed: () => showCsvImportDialog(context, ref),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PR ticker
// ---------------------------------------------------------------------------

class _PrTicker extends StatelessWidget {
  const _PrTicker({required this.prs, required this.now});
  final List<PersonalRecord> prs;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    if (prs.isEmpty) {
      return GlassPanel(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            const GlowIcon(Icons.emoji_events_outlined, color: AppColors.gold),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'No records yet. Each lift needs a baseline session first.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: prs.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) => Entrance(
          delay: AppMotion.staggerStep * i.clamp(0, AppMotion.staggerCap),
          offset: const Offset(18, 0),
          child: _PrCard(pr: prs[i], now: now, fresh: i == 0),
        ),
      ),
    );
  }
}

class _PrCard extends StatelessWidget {
  const _PrCard({required this.pr, required this.now, required this.fresh});
  final PersonalRecord pr;
  final DateTime now;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final (label, value, unit, delta) = switch (pr.type) {
      PrType.e1Rm => (
        'E1RM',
        Fmt.oneDp(pr.value),
        'kg',
        signed(pr.value - pr.previous, unit: ' kg'),
      ),
      PrType.weight => (
        'TOP SET',
        Fmt.oneDp(pr.value),
        'kg',
        signed(pr.value - pr.previous, unit: ' kg'),
      ),
      PrType.repsAtWeight => (
        'REPS @ ${Fmt.oneDp(pr.weightKg ?? 0)} KG',
        '${pr.value.toInt()}',
        'reps',
        signed(pr.value - pr.previous, digits: 0, unit: ' reps'),
      ),
      PrType.volume => (
        'VOLUME',
        Fmt.integer(pr.value),
        'kg',
        signed(pr.value - pr.previous, digits: 0, unit: ' kg'),
      ),
    };
    final days = LocalDates.parse(LocalDates.key(now))
        .difference(LocalDates.parse(LocalDates.key(pr.date)))
        .inDays;
    final when = days <= 0
        ? 'today'
        : days == 1
        ? 'yesterday'
        : days < 7
        ? Fmt.weekdayDayMonth(pr.date).split(',').first
        : Fmt.dayMonth(pr.date);
    return SizedBox(
      width: 172,
      child: AppCard(
        accent: AppColors.gold,
        glow: fresh,
        animateEntrance: false,
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: () => context.push('/workout/${pr.workoutId}'),
        semanticLabel:
            'PR: ${pr.exerciseName}, ${pr.type.label} $value $unit, $when',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const GlowIcon(
                  Icons.emoji_events,
                  color: AppColors.gold,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: hud.label(size: 10.5, color: AppColors.gold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(when, style: hud.mono(size: 9.5)),
              ],
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                AnimatedTicker(
                  value,
                  style: hud.number(size: 28, color: hud.text),
                ),
                const SizedBox(width: 3),
                Text(unit, style: hud.label(size: 11)),
                const Spacer(),
                Text(
                  delta,
                  style: hud
                      .mono(size: 10.5, color: AppColors.success)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            Text(
              pr.exerciseName,
              style: t.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Latest, quick links, sync
// ---------------------------------------------------------------------------

class _LatestCard extends StatelessWidget {
  const _LatestCard({required this.workout, required this.run});
  final WorkoutLog? workout;
  final RunActivity? run;

  @override
  Widget build(BuildContext context) {
    final w = workout;
    final r = run;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        children: [
          if (w != null)
            HudRow(
              leading: const HudBadge(
                icon: Icons.fitness_center,
                color: AppColors.strength,
              ),
              title: w.title,
              subtitle: [
                Fmt.weekdayDayMonth(w.startAt),
                '${workingSetCount(w)} sets',
                '${Fmt.integer(sessionVolume(w))} kg',
              ].join(' · '),
              footer: SourceBadge(origin: DataOrigin.fromKey(w.source)),
              onTap: () => context.push('/workout/${w.id}'),
            ),
          if (w != null && r != null) const HudDivider(height: 1),
          if (r != null)
            HudRow(
              leading: const HudBadge(
                icon: Icons.directions_run,
                color: AppColors.running,
              ),
              title: r.name ?? 'Run',
              subtitle: [
                Fmt.weekdayDayMonth(r.startAt),
                if (r.distanceM != null) Fmt.km(r.distanceM!),
                if (r.paceSPerKm != null) Fmt.pace(r.paceSPerKm!),
              ].join(' · '),
              footer: SourceBadge(origin: DataOrigin.fromKey(r.source)),
              onTap: () => context.push('/running/activity/${r.id}'),
            ),
        ],
      ),
    );
  }
}

class _QuickGrid extends ConsumerWidget {
  const _QuickGrid({
    required this.workouts,
    required this.cardio,
    required this.today,
  });
  final List<WorkoutLog> workouts;
  final List<RunActivity> cardio;
  final String today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strength = weeklyStrength(workouts, todayKey: today, weeks: 8);
    final running = weeklyRunning(cardio, todayKey: today, weeks: 8);
    final steps = ref.watch(todayStepsProvider).value;
    final goal = ref.watch(profileProvider).value?.stepGoal ?? 0;
    final vol = strength.last.volumeKg;
    final km = running.last.distanceM / 1000;
    Widget tile({
      required IconData icon,
      required String label,
      required String value,
      required String sub,
      required Color color,
      required VoidCallback onTap,
      List<double>? spark,
      double? ring,
    }) => Expanded(
      child: AppCard(
        accent: color,
        onTap: onTap,
        semanticLabel: '$label: $value, $sub',
        padding: const EdgeInsets.all(AppSpacing.md),
        child: SizedBox(
          height: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GlowIcon(icon, color: color, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      style: context.hud.label(size: 11),
                    ),
                  ),
                  if (ring != null)
                    SizedBox.square(
                      dimension: 22,
                      child: ProgressRing(
                        progress: ring,
                        color: color,
                        size: 22,
                        stroke: 3,
                        ticks: false,
                        celebrate: false,
                      ),
                    ),
                ],
              ),
              const Spacer(),
              AnimatedTicker(
                value,
                style: context.hud.number(size: 22, color: context.hud.text),
              ),
              Text(
                sub,
                style: context.hud.mono(size: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (spark != null && spark.where((v) => v > 0).length >= 2)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: HudSparkline(
                    values: spark,
                    color: color,
                    height: 14,
                    strokeWidth: 1.5,
                    fill: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            tile(
              icon: Icons.fitness_center,
              label: 'Strength',
              value: vol >= 10000
                  ? '${(vol / 1000).toStringAsFixed(1)}k kg'
                  : '${Fmt.integer(vol)} kg',
              sub: 'volume this week',
              color: AppColors.strength,
              spark: [for (final w in strength) w.volumeKg],
              onTap: () => context.push(AppPaths.strength),
            ),
            const SizedBox(width: AppSpacing.md),
            tile(
              icon: Icons.directions_run,
              label: 'Running',
              value: '${km.toStringAsFixed(1)} km',
              sub: '5K goal 30:00',
              color: AppColors.running,
              spark: [for (final w in running) w.distanceM / 1000],
              onTap: () => context.push(AppPaths.running),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            tile(
              icon: Icons.directions_walk,
              label: 'Steps',
              value: steps == null ? '—' : Fmt.integer(steps.steps),
              sub: steps == null
                  ? 'goal ${Fmt.integer(goal)} · not synced'
                  : 'of ${Fmt.integer(goal)} today',
              color: AppColors.steps,
              ring: steps == null || goal <= 0 ? null : steps.steps / goal,
              onTap: () => context.push(AppPaths.steps),
            ),
            const SizedBox(width: AppSpacing.md),
            tile(
              icon: Icons.edit_note,
              label: 'Log',
              value: 'Workout',
              sub: 'manual · rest timer',
              color: AppColors.cyan,
              onTap: () => LogWorkoutScreen.open(context),
            ),
          ],
        ),
      ],
    );
  }
}

class _SyncChips extends ConsumerWidget {
  const _SyncChips({required this.now});
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hevy = ref.watch(integrationStatusProvider(Providers.hevy)).value;
    final strava = ref.watch(integrationStatusProvider(Providers.strava)).value;
    final hc = ref.watch(healthConnectionProvider).value;
    final sync = ref.watch(syncControllerProvider);
    final hevyStatus = displayStatus(hevy);
    final stravaStatus = displayStatus(strava, configured: Env.hasStrava);
    final hcStatus = displayStatus(hc);
    String label(
      String name,
      IntegrationDisplayStatus s,
      IntegrationConnection? row,
      bool busy,
    ) {
      if (busy) return '$name · syncing';
      if (s == IntegrationDisplayStatus.connected) {
        final last = row?.lastSyncAt;
        return last == null
            ? '$name · connected'
            : '$name · ${Fmt.ago(last.toLocal(), now)}';
      }
      return '$name · ${s == IntegrationDisplayStatus.awaitingCredentials ? 'awaiting keys' : s.label.toLowerCase()}';
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        HudChip(
          label: label('Hevy', hevyStatus, hevy, sync.hevy),
          dot: true,
          color: hevyStatus.color,
          onTap: () => _syncSheet(
            context,
            ref,
            name: 'Hevy',
            color: AppColors.strength,
            row: hevy,
            configured: true,
            syncing: sync.hevy,
            onSync: ref.read(syncControllerProvider.notifier).syncHevy,
          ),
        ),
        HudChip(
          label: label('Strava', stravaStatus, strava, sync.strava),
          dot: true,
          color: stravaStatus.color,
          onTap: () => _syncSheet(
            context,
            ref,
            name: 'Strava',
            color: kStravaOrange,
            row: strava,
            configured: Env.hasStrava,
            syncing: sync.strava,
            onSync: ref.read(syncControllerProvider.notifier).syncStrava,
          ),
        ),
        HudChip(
          label: label('Health Connect', hcStatus, hc, false),
          dot: true,
          color: hcStatus.color,
          onTap: () => context.push(AppPaths.healthStatus),
        ),
      ],
    );
  }

  void _syncSheet(
    BuildContext context,
    WidgetRef ref, {
    required String name,
    required Color color,
    required IntegrationConnection? row,
    required bool configured,
    required bool syncing,
    required Future<String> Function() onSync,
  }) {
    showHudBottomSheet<void>(
      context,
      title: name,
      builder: (ctx) => SyncStatusTile(
        name: name,
        color: color,
        row: row,
        configured: configured,
        syncing: syncing,
        now: now,
        onSync: () async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          Navigator.pop(ctx);
          final msg = await onSync();
          messenger?.showSnackBar(SnackBar(content: Text(msg)));
        },
        onSetup: () {
          Navigator.pop(ctx);
          context.push(AppPaths.integrations);
        },
      ),
    );
  }
}
