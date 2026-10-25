import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../train/application/train_providers.dart';
import '../../train/domain/running_models.dart';
import '../../train/domain/strength_models.dart';
import '../../train/domain/workout_draft.dart';
import '../../train/presentation/log_workout_screen.dart';
import '../../train/presentation/widgets/hud_kit.dart';
import '../../train/presentation/widgets/week_plan.dart';
import '../application/persona_providers.dart';
import '../domain/training_program.dart';

/// The weekly program: mesocycle position, a selectable week of day nodes
/// and the selected day's session (exercises with sets × reps, RIR and rest,
/// or the run with pace zones), deload / readiness / injury notices and the
/// "Start session" hand-off to the logger.
///
/// Opened from Today (hero `planned-session-<date>`) or from the Train tab
/// (`/train/program?hero=train`, hero `train-planned-session-<date>`) so
/// each tab owns a unique hero tag.
class ProgramScreen extends ConsumerStatefulWidget {
  const ProgramScreen({super.key});

  @override
  ConsumerState<ProgramScreen> createState() => _ProgramScreenState();
}

class _ProgramScreenState extends ConsumerState<ProgramScreen> {
  late final String _today = LocalDates.key(ref.read(clockProvider).now());
  late String _date = _today;
  bool _useLighter = false;
  String _heroPrefix = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      final from = GoRouterState.of(context).uri.queryParameters['hero'];
      _heroPrefix = from == null || from.isEmpty ? '' : '$from-';
    } catch (_) {
      _heroPrefix = '';
    }
  }

  void _select(String d) {
    if (d == _date) return;
    setState(() {
      _date = d;
      _useLighter = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final program = ref.watch(activeProgramProvider);
    final session = ref.watch(plannedSessionProvider(_date));
    final workouts = ref.watch(workoutLogsProvider).value ?? const [];
    final cardio = ref.watch(cardioActivitiesProvider).value ?? const [];
    final p = program.value;
    final week = p?.weekNumber(_today);
    return AppPage(
      title: 'Program',
      eyebrow: p == null
          ? 'JARVIS · TRAINING PLAN'
          : 'WEEK $week · ${p.isDeloadWeek(week!) ? 'DELOAD WEEK' : 'DELOAD EVERY ${p.deloadEvery}TH WEEK'}',
      subtitle: p?.name,
      children: [
        program.when(
          loading: () => const ScanlineLoader(height: 160, lines: 0),
          error: (e, _) => const ErrorState(message: 'Could not load program.'),
          data: (p) => p == null
              ? AppCard(
                  child: EmptyState(
                    icon: Icons.auto_awesome,
                    eyebrow: 'NO PROGRAM',
                    title: 'No program yet',
                    message:
                        'Run JARVIS calibration to generate your 5 lift + 2 '
                        'run week.',
                    actionLabel: 'Calibrate',
                    onAction: () => context.push(AppPaths.onboarding),
                    compact: true,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PlannerCard(
                      program: p,
                      today: _today,
                      selected: _date,
                      days: planWeek(
                        program: p,
                        today: _today,
                        workouts: workouts,
                        activities: cardio,
                      ),
                      onSelect: _select,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AnimatedSwitcher(
                      duration: AppMotion.medium,
                      switchInCurve: AppMotion.emphasizedDecelerate,
                      switchOutCurve: AppMotion.emphasizedAccelerate,
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.025),
                            end: Offset.zero,
                          ).animate(a),
                          child: child,
                        ),
                      ),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey('$_date-$_useLighter'),
                        child: session.when(
                          loading: () => const ScanlineLoader(lines: 4),
                          error: (e, _) => const ErrorState(
                            message: 'Could not plan this session.',
                          ),
                          data: (s) => s == null
                              ? const SizedBox.shrink()
                              : _SessionDetail(
                                  session: s,
                                  isToday: _date == _today,
                                  heroPrefix: _heroPrefix,
                                  useLighter: _useLighter,
                                  logged: _loggedFor(s, workouts, cardio),
                                  onToggleLighter: (v) =>
                                      setState(() => _useLighter = v),
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

  /// What was logged on the session's date (for the "done" state).
  _Logged? _loggedFor(
    PlannedSession s,
    List<WorkoutLog> workouts,
    List<RunActivity> cardio,
  ) {
    if (s.day.kind == SessionKind.run) {
      final r = cardio.where((a) => a.isRun && a.localDate == s.date);
      return r.isEmpty ? null : _Logged(run: r.first);
    }
    final w = workouts.where((w) => w.localDate == s.date);
    return w.isEmpty ? null : _Logged(workout: w.first);
  }
}

class _Logged {
  const _Logged({this.workout, this.run});
  final WorkoutLog? workout;
  final RunActivity? run;
}

// ---------------------------------------------------------------------------
// Planner (mesocycle + week)
// ---------------------------------------------------------------------------

class _PlannerCard extends StatelessWidget {
  const _PlannerCard({
    required this.program,
    required this.today,
    required this.selected,
    required this.days,
    required this.onSelect,
  });

  final TrainingProgram program;
  final String today;
  final String selected;
  final List<PlanDay> days;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final week = program.weekNumber(today);
    final n = program.deloadEvery;
    final pos = (week - 1) % n;
    final deload = program.isDeloadWeek(week);
    final done = days.where((d) => d.done).length;
    final monday = LocalDates.parse(LocalDates.weekStart(today));
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('WEEK', style: hud.label(size: 12)),
              const SizedBox(width: 6),
              AnimatedTicker('$week', style: hud.number(size: 30)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    'from ${Fmt.dayMonth(monday)}',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: deload
                    ? const HudChip(
                        label: 'Deload week',
                        color: AppColors.warning,
                        dot: true,
                      )
                    : HudChip(label: '$done/7 done', dot: done > 0),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          CycleBar(program: program, week: week),
          const SizedBox(height: 6),
          Text(
            deload
                ? 'BLOCK ${(week - 1) ~/ n + 1} · DELOAD: −40% SETS, +1 RIR'
                : 'BLOCK ${(week - 1) ~/ n + 1} · WEEK ${pos + 1} OF $n · '
                      'DELOAD IN ${n - 1 - pos} WK',
            style: hud.mono(size: 10.5),
          ),
          const SizedBox(height: AppSpacing.lg),
          WeekNodes(
            days: days,
            today: today,
            selected: selected,
            onSelect: onSelect,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Session detail
// ---------------------------------------------------------------------------

class _SessionDetail extends ConsumerWidget {
  const _SessionDetail({
    required this.session,
    required this.isToday,
    required this.heroPrefix,
    required this.useLighter,
    required this.logged,
    required this.onToggleLighter,
  });

  final PlannedSession session;
  final bool isToday;
  final String heroPrefix;
  final bool useLighter;
  final _Logged? logged;
  final ValueChanged<bool> onToggleLighter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final lighter = session.lighter;
    final day = useLighter && lighter != null ? lighter : session.day;
    final hevy = ref.watch(integrationStatusProvider(Providers.hevy)).value;
    final start = ref.watch(calibrationProvider).value?.trainingStart;
    final zones = session.program.paces;
    final color = sessionColor(day.kind);
    final children = <Widget>[
      Hero(
        tag: '$heroPrefix${session.heroTag}',
        child: SessionHeaderCard(
          session: session,
          day: day,
          startMinutes: isToday ? start : null,
          done: logged != null,
          animateEntrance: false,
        ),
      ),
    ];

    void gap() => children.add(const SizedBox(height: AppSpacing.md));

    if (session.isDeload) {
      gap();
      children.add(
        NoticeBanner(
          icon: Icons.battery_charging_full,
          color: AppColors.warning,
          message:
              'Deload week ${session.week}: about 40% fewer sets and +1 RIR. '
              'Let fatigue drop so the next block starts fresh.',
        ),
      );
    }
    if (isToday && lighter != null) {
      gap();
      children.add(
        NoticeBanner(
          icon: Icons.bolt,
          color: AppColors.warning,
          message:
              'Readiness is low (${session.readiness.reason}). A lighter '
              'session is suggested: one fewer set, +1 RIR.',
          actionLabel: useLighter ? 'Use full' : 'Go lighter',
          onAction: () {
            Haptics.selection();
            onToggleLighter(!useLighter);
          },
        ),
      );
    }
    for (final w in session.warnings) {
      gap();
      children.add(_SwapCard(warning: w));
    }

    final run = day.run;
    if (run != null) {
      children.add(
        const SectionHeader(
          'Run',
          subtitle: 'Pace targets are estimates',
          accent: AppColors.running,
        ),
      );
      children.add(_RunPlanCard(run: run));
      gap();
      children.add(_PaceZonesCard(zones: zones, active: run.type));
    }

    if (day.exercises.isNotEmpty) {
      children.add(
        SectionHeader(
          'Exercises',
          subtitle: '${day.totalSets} sets · tap for cues',
          accent: color,
        ),
      );
      children.add(
        StaggeredList(
          gap: AppSpacing.sm,
          children: [
            for (var i = 0; i < day.exercises.length; i++)
              _ExerciseCard(index: i, plan: day.exercises[i], color: color),
          ],
        ),
      );
      gap();
      children.add(
        GlassPanel(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlowIcon(Icons.trending_up, size: 18, color: hud.accent),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  TrainingProgram.progressionRule,
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ),
            ],
          ),
        ),
      );
    }

    children.add(const SizedBox(height: AppSpacing.xl));
    final done = logged;
    if (done?.workout != null) {
      children.add(
        HudButton.secondary(
          label: 'View logged workout',
          icon: Icons.check_circle_outline,
          expand: true,
          onPressed: () => context.push('/workout/${done!.workout!.id}'),
        ),
      );
      children.add(const SizedBox(height: AppSpacing.sm));
    } else if (done?.run != null) {
      children.add(
        HudButton.secondary(
          label: 'View logged run',
          icon: Icons.check_circle_outline,
          expand: true,
          onPressed: () => context.push('/running/activity/${done!.run!.id}'),
        ),
      );
      children.add(const SizedBox(height: AppSpacing.sm));
    }
    if (day.exercises.isNotEmpty) {
      children.add(
        HudButton(
          label: done?.workout != null
              ? 'Log another session'
              : 'Start session',
          icon: Icons.play_arrow_rounded,
          expand: true,
          onPressed: () => LogWorkoutScreen.open(
            context,
            initial: workoutDraftFor(day, ref.read(clockProvider).now()),
            restSeconds: [for (final e in day.exercises) e.restSeconds],
          ),
        ),
      );
      if (isConnected(hevy)) {
        children.add(const SizedBox(height: AppSpacing.sm));
        children.add(
          HudButton.ghost(
            label: 'Log in Hevy instead',
            icon: Icons.open_in_new,
            expand: true,
            onPressed: () => launchUrl(
              Uri.parse('https://hevy.com/'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        );
      }
    }
    if (run != null) {
      children.add(
        Text(
          'Record the run with your phone app; it appears here once it '
          'syncs from Strava or Health Connect.',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Pre-fills a manual workout from a planned session (sets left blank for
/// the user to fill in weight and reps).
WorkoutDraft workoutDraftFor(ProgramDay day, DateTime start) => WorkoutDraft(
  title: day.title,
  startAt: start,
  endAt: start.add(Duration(minutes: day.minutes)),
  notes: 'Planned by JARVIS · ${day.focus}',
  exercises: [
    for (final e in day.exercises)
      ExerciseDraft(
        name: e.name,
        muscleGroup: e.info?.muscle,
        notes: '${e.sets} × ${e.repRange} @ RIR ${e.rir}',
        sets: [for (var i = 0; i < e.sets; i++) const SetDraft()],
      ),
  ],
);

String _hhmm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Session headline used on the program screen and (via Hero) on Today and
/// the Train tab.
class SessionHeaderCard extends StatelessWidget {
  const SessionHeaderCard({
    super.key,
    required this.session,
    this.day,
    this.onTap,
    this.compact = false,
    this.startMinutes,
    this.done = false,
    this.animateEntrance = true,
  });

  final PlannedSession session;

  /// Overrides the session's day (e.g. the lighter variant).
  final ProgramDay? day;
  final VoidCallback? onTap;
  final bool compact;

  /// Planned start (minutes after midnight), shown as a chip.
  final int? startMinutes;
  final bool done;
  final bool animateEntrance;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final day = this.day ?? session.day;
    final color = sessionColor(day.kind);
    final date = LocalDates.parse(session.date);
    final run = day.run;
    final eyebrow = compact
        ? 'TODAY · WEEK ${session.week}'
        : 'WEEK ${session.week} · ${weekdayShort[date.weekday - 1]} '
              '${Fmt.dayMonth(date).toUpperCase()}';
    // Run days: the run card below carries duration and pace.
    final stats = run != null
        ? const <(String, String)>[]
        : <(String, String)>[
            ('EXERCISES', '${day.exercises.length}'),
            ('SETS', '${day.totalSets}'),
            ('MIN', '~${day.minutes}'),
          ];
    final sub = run != null
        ? '${run.minutes} min · ${formatPaceRange(run.paceMinS, run.paceMaxS)}'
        : '${day.exercises.length} exercises · ${day.totalSets} sets · '
              '~${day.minutes} min';
    return Material(
      type: MaterialType.transparency,
      child: AppCard(
        accent: color,
        onTap: onTap,
        brackets: !compact,
        animateEntrance: animateEntrance,
        semanticLabel: 'Planned session: ${day.title}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                HudBadge(icon: sessionIcon(day.kind), color: color, size: 44),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: hud.label(size: 11.5, color: color),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        day.title,
                        style: (compact ? t.titleMedium : t.titleLarge)
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        compact ? sub : day.focus,
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (done)
                  const HudChip(
                    label: 'Done',
                    icon: Icons.check,
                    color: AppColors.success,
                  )
                else if (onTap != null)
                  Icon(Icons.chevron_right, color: hud.textMuted),
              ],
            ),
            if (!compact && stats.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  for (final (label, value) in stats)
                    Expanded(
                      flex: value.length > 6 ? 2 : 1,
                      child: HudReadout(label: label, value: value, size: 26),
                    ),
                ],
              ),
            ],
            if (!compact) ...[
              if (startMinutes != null || session.isDeload) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    if (startMinutes != null)
                      HudChip(
                        label: 'Starts ${_hhmm(startMinutes!)}',
                        icon: Icons.schedule,
                      ),
                    if (session.isDeload)
                      const HudChip(
                        label: 'Deload',
                        color: AppColors.warning,
                        dot: true,
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Exercises
// ---------------------------------------------------------------------------

/// "2:30" for ≥ 60 s, "45 s" below.
String restLabel(int s) =>
    s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}' : '$s s';

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.index,
    required this.plan,
    required this.color,
  });
  final int index;
  final ExercisePlan plan;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final muscle = plan.info?.muscle;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: () => _showDetail(context),
      semanticLabel:
          '${plan.name}: ${plan.sets} sets of ${plan.repRange} reps, '
          'RIR ${plan.rir}, rest ${restLabel(plan.restSeconds)}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HudBadge(
            text: (index + 1).toString().padLeft(2, '0'),
            color: color,
            size: 36,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name, style: t.titleSmall),
                if (muscle != null)
                  Text(
                    muscle,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var s = 0; s < plan.sets; s++)
                          Container(
                            width: 12,
                            height: 5,
                            margin: const EdgeInsets.only(right: 3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: color.withValues(alpha: 0.85),
                              boxShadow: [
                                BoxShadow(
                                  color: color.withValues(
                                    alpha: 0.4 * hud.glowStrength,
                                  ),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(width: 3),
                        Text(
                          '${plan.sets} × ${plan.repRange}',
                          style: hud
                              .mono(size: 11.5, color: hud.text)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    HudTag('RIR ${plan.rir}', color: hud.accentInk),
                    if (plan.restSeconds > 0)
                      HudTag('REST ${restLabel(plan.restSeconds)}'),
                  ],
                ),
                if (plan.note != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    plan.note!,
                    style: t.bodySmall?.copyWith(color: AppColors.warning),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context) {
    final info = plan.info;
    showHudBottomSheet<void>(
      context,
      title: plan.name,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        final hud = ctx.hud;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info != null)
              Text(
                info.muscle.toUpperCase(),
                style: hud.label(size: 12, color: color),
              ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: HudReadout(label: 'Sets', value: '${plan.sets}'),
                ),
                Expanded(
                  child: HudReadout(label: 'Reps', value: plan.repRange),
                ),
                Expanded(
                  child: HudReadout(label: 'RIR', value: '${plan.rir}'),
                ),
                Expanded(
                  child: HudReadout(
                    label: 'Rest',
                    value: restLabel(plan.restSeconds),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Leave ${plan.rir} rep${plan.rir == 1 ? '' : 's'} in reserve on '
              'every working set.',
              style: t.bodyMedium,
            ),
            if (info?.cue.isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.md),
              _SheetLine(
                icon: Icons.record_voice_over_outlined,
                text: 'Cue: ${info!.cue}',
              ),
            ],
            if (info?.substitute != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _SheetLine(
                icon: Icons.swap_horiz,
                text: 'Swap if needed: ${info!.substitute}',
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              TrainingProgram.progressionRule,
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ],
        );
      },
    );
  }
}

class _SheetLine extends StatelessWidget {
  const _SheetLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: context.hud.accent),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    ],
  );
}

/// Injury substitution / caution, styled as an alert slab.
class _SwapCard extends StatelessWidget {
  const _SwapCard({required this.warning});
  final ExerciseWarning warning;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final w = warning;
    final swapped = w.substitute != null;
    final c = swapped ? AppColors.warning : AppColors.danger;
    return AppCard(
      accent: c,
      padding: const EdgeInsets.all(AppSpacing.md),
      semanticLabel: swapped
          ? '${w.original} swapped for ${w.substitute} because of '
                '${w.restriction}'
          : '${w.original}: caution, ${w.restriction}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HudBadge(icon: Icons.healing_outlined, color: c, size: 36),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  swapped ? 'SAFE SWAP' : 'CAUTION',
                  style: hud.label(size: 11, color: c),
                ),
                Text(
                  swapped
                      ? '${w.original} → ${w.substitute}'
                      : '${w.original}: no safe substitute',
                  style: t.titleSmall,
                ),
                Text(
                  swapped
                      ? 'Because of "${w.restriction}".'
                      : '${w.restriction}. Use a pain-free range or skip it.',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

class _RunPlanCard extends StatelessWidget {
  const _RunPlanCard({required this.run});
  final RunPlan run;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      accent: AppColors.running,
      semanticLabel:
          '${run.type} run, ${run.minutes} minutes at '
          '${formatPaceRange(run.paceMinS, run.paceMaxS)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HudTag(
                run.type.replaceAll('_', ' ').toUpperCase(),
                color: AppColors.running,
              ),
              const Spacer(),
              const HudTag('PACE = ESTIMATE', color: AppColors.warning),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Duration',
                  value: '${run.minutes}',
                  unit: 'min',
                ),
              ),
              Expanded(
                flex: 2,
                child: HudReadout(
                  label: 'Target pace',
                  value: formatPaceRange(
                    run.paceMinS,
                    run.paceMaxS,
                  ).replaceAll('/km', ''),
                  unit: '/km',
                  color: AppColors.running,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(run.description, style: t.bodyMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Effort beats the watch: if it feels harder than planned, slow '
            'down.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Pace zones as a ladder on a shared pace axis (faster to the right), the
/// zone used today highlighted. All values are estimates from the goal.
class _PaceZonesCard extends StatelessWidget {
  const _PaceZonesCard({required this.zones, required this.active});
  final PaceZones zones;
  final String active;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final rows = <(String, String, (int, int), String)>[
      ('easy', 'Easy / Zone 2', zones.easy, 'conversational'),
      ('tempo', 'Tempo', zones.tempo, 'comfortably hard'),
      ('intervals', 'Intervals', zones.interval, 'hard, controlled'),
      ('goal_pace', 'Goal 5K', zones.goal, 'race pace'),
    ];
    final slowest = zones.easy.$2 + 15;
    final fastest = zones.interval.$1 - 15;
    double x(int s) => ((slowest - s) / (slowest - fastest)).clamp(0.0, 1.0);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Pace zones (estimates)', style: t.titleSmall),
              ),
              Text('SLOW → FAST', style: hud.mono(size: 9.5)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (final (key, label, range, note) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: label,
                                style: t.labelLarge?.copyWith(
                                  color: key == active
                                      ? AppColors.running
                                      : null,
                                ),
                              ),
                              TextSpan(
                                text: '  $note',
                                style: t.bodySmall?.copyWith(
                                  color: hud.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Text(
                        formatPaceRange(range.$1, range.$2),
                        style: hud
                            .mono(size: 12, color: hud.text)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LayoutBuilder(
                    builder: (context, box) {
                      final a = x(range.$2) * box.maxWidth;
                      final b = x(range.$1) * box.maxWidth;
                      final on = key == active;
                      return SizedBox(
                        height: 6,
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: hud.hairline.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            Positioned(
                              left: a,
                              width: (b - a).clamp(6.0, box.maxWidth),
                              top: 0,
                              bottom: 0,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3),
                                  color: AppColors.running.withValues(
                                    alpha: on ? 1 : 0.45,
                                  ),
                                  boxShadow: on
                                      ? [
                                          BoxShadow(
                                            color: AppColors.running.withValues(
                                              alpha: 0.6 * hud.glowStrength,
                                            ),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          Text(
            'Derived from your goal pace (${formatPace(zones.goalPaceS)}/km). '
            'They move as your 5K estimate improves.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Compact "today's session" card for Today. Renders nothing until JARVIS
/// calibration has created a program.
///
/// Only one host per screen stack should set [hero] (Today does) so the tag
/// stays unique while both tabs are alive.
class PlannedSessionCard extends ConsumerWidget {
  const PlannedSessionCard({
    super.key,
    this.bottomGap = AppSpacing.md,
    this.hero = false,
  });
  final double bottomGap;
  final bool hero;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(todaysPlannedSessionProvider).value;
    if (s == null) return const SizedBox.shrink();
    final card = SessionHeaderCard(
      session: s,
      compact: true,
      animateEntrance: !hero,
      onTap: () => context.push(AppPaths.program),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottomGap),
      child: hero ? Hero(tag: s.heroTag, child: card) : card,
    );
  }
}
