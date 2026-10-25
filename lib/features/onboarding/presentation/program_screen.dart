import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../life/domain/habit_models.dart';
import '../../train/application/train_providers.dart';
import '../../train/domain/workout_draft.dart';
import '../../train/presentation/log_workout_screen.dart';
import '../application/persona_providers.dart';
import '../domain/training_program.dart';

/// Weekly program: calendar strip, selected day's session, exercise details,
/// pace zones, Start session / Log in Hevy.
class ProgramScreen extends ConsumerStatefulWidget {
  const ProgramScreen({super.key});

  @override
  ConsumerState<ProgramScreen> createState() => _ProgramScreenState();
}

class _ProgramScreenState extends ConsumerState<ProgramScreen> {
  late final String _today = LocalDates.key(ref.read(clockProvider).now());
  late String _date = _today;
  bool _useLighter = false;

  @override
  Widget build(BuildContext context) {
    final program = ref.watch(activeProgramProvider);
    final session = ref.watch(plannedSessionProvider(_date));
    return AppPage(
      title: 'Program',
      subtitle: program.value?.name,
      children: [
        program.when(
          loading: () => const LoadingState(),
          error: (e, _) => const ErrorState(message: 'Could not load program.'),
          data: (p) => p == null
              ? AppCard(
                  child: EmptyState(
                    icon: Icons.auto_awesome,
                    title: 'No program yet',
                    message: 'Run JARVIS calibration to generate your plan.',
                    actionLabel: 'Calibrate',
                    onAction: () => context.push(AppPaths.onboarding),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _WeekStrip(
                      program: p,
                      today: _today,
                      selected: _date,
                      onSelect: (d) => setState(() {
                        _date = d;
                        _useLighter = false;
                      }),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AnimatedSwitcher(
                      duration: AppDurations.medium,
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(a),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey('$_date-$_useLighter'),
                        child: session.when(
                          loading: () => const LoadingState(),
                          error: (e, _) => const ErrorState(
                            message: 'Could not plan this session.',
                          ),
                          data: (s) => s == null
                              ? const SizedBox.shrink()
                              : _SessionDetail(
                                  session: s,
                                  isToday: _date == _today,
                                  useLighter: _useLighter,
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
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.program,
    required this.today,
    required this.selected,
    required this.onSelect,
  });

  final TrainingProgram program;
  final String today;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final monday = LocalDates.weekStart(today);
    final week = program.weekNumber(today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Week $week', style: t.titleMedium),
            const SizedBox(width: AppSpacing.sm),
            if (program.isDeloadWeek(week))
              const _Badge('DELOAD', AppColors.warning),
            const Spacer(),
            Text(
              'Deload every ${program.deloadEvery}th week',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Builder(
                  builder: (context) {
                    final date = LocalDates.addDays(monday, i);
                    final day = program.sessionFor(date);
                    final isSel = date == selected;
                    final color = day.kind == SessionKind.run
                        ? AppColors.running
                        : day.kind == SessionKind.recovery
                        ? AppColors.habit
                        : AppColors.strength;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        onTap: () => onSelect(date),
                        child: AnimatedContainer(
                          duration: AppDurations.medium,
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: isSel
                                ? color.withValues(alpha: 0.18)
                                : scheme.surface,
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            border: Border.all(
                              color: date == today
                                  ? color
                                  : scheme.outlineVariant,
                              width: date == today ? 1.5 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                weekdayLetter[i],
                                style: t.labelMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Icon(_kindIcon(day.kind), size: 18, color: color),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                _shortTitle(day.title),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}

String _shortTitle(String title) => title.split(' ').first;

IconData _kindIcon(SessionKind k) => switch (k) {
  SessionKind.lift => Icons.fitness_center,
  SessionKind.run => Icons.directions_run,
  SessionKind.recovery => Icons.spa_outlined,
};

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: AppRadii.chip,
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}

class _SessionDetail extends ConsumerWidget {
  const _SessionDetail({
    required this.session,
    required this.isToday,
    required this.useLighter,
    required this.onToggleLighter,
  });

  final PlannedSession session;
  final bool isToday;
  final bool useLighter;
  final ValueChanged<bool> onToggleLighter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final lighter = session.lighter;
    final day = useLighter && lighter != null ? lighter : session.day;
    final hevy = ref.watch(integrationStatusProvider(Providers.hevy)).value;
    final zones = session.program.paces;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Hero(
          tag: session.heroTag,
          child: SessionHeaderCard(session: session, day: day),
        ),
        if (isToday && lighter != null) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            icon: Icons.battery_charging_full,
            color: AppColors.warning,
            message:
                'Readiness is low (${session.readiness.reason}). A lighter '
                'session is suggested: one fewer set, +1 RIR.',
            actionLabel: useLighter ? 'Use full' : 'Go lighter',
            onAction: () => onToggleLighter(!useLighter),
          ),
        ],
        for (final w in session.warnings) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            icon: Icons.healing_outlined,
            color: AppColors.danger,
            message: w.substitute == null
                ? '${w.original}: caution — ${w.restriction}. No safe '
                      'substitute; use pain-free range or skip.'
                : '${w.original} → ${w.substitute} because of '
                      '"${w.restriction}".',
          ),
        ],
        if (day.run != null) ...[
          const SectionHeader(
            'Run',
            subtitle: 'Paces are estimates from your goal',
          ),
          AppCard(
            accent: AppColors.running,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${day.run!.minutes} min · '
                  '${formatPaceRange(day.run!.paceMinS, day.run!.paceMaxS)}',
                  style: t.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(day.run!.description, style: t.bodyMedium),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _PaceZonesCard(zones: zones),
        ],
        if (day.exercises.isNotEmpty) ...[
          SectionHeader(
            'Exercises',
            subtitle: '${day.totalSets} working sets · tap for details',
          ),
          for (var i = 0; i < day.exercises.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ExerciseTile(index: i, plan: day.exercises[i]),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.trending_up, color: scheme.primary, size: 20),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    TrainingProgram.progressionRule,
                    style: t.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (day.exercises.isNotEmpty)
          FilledButton.icon(
            onPressed: () => LogWorkoutScreen.open(
              context,
              initial: workoutDraftFor(day, ref.read(clockProvider).now()),
            ),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start session'),
          ),
        if (day.exercises.isNotEmpty && isConnected(hevy)) ...[
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://hevy.com/'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Log in Hevy'),
          ),
        ],
        if (day.run != null)
          Text(
            'Runs are picked up from Strava or Health Connect once synced.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
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

/// Session headline used on the program screen and (via Hero) on Today/Train.
class SessionHeaderCard extends StatelessWidget {
  const SessionHeaderCard({
    super.key,
    required this.session,
    this.day,
    this.onTap,
    this.compact = false,
  });

  final PlannedSession session;

  /// Overrides the session's day (e.g. the lighter variant).
  final ProgramDay? day;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final day = this.day ?? session.day;
    final color = day.kind == SessionKind.run
        ? AppColors.running
        : day.kind == SessionKind.recovery
        ? AppColors.habit
        : AppColors.strength;
    final sub = day.run != null
        ? '${day.run!.minutes} min · '
              '${formatPaceRange(day.run!.paceMinS, day.run!.paceMaxS)}'
        : '${day.exercises.length} exercises · ${day.totalSets} sets · '
              '~${day.minutes} min';
    return Material(
      type: MaterialType.transparency,
      child: AppCard(
        accent: color,
        onTap: onTap,
        semanticLabel: 'Planned session: ${day.title}',
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Icon(_kindIcon(day.kind), color: color),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    compact
                        ? 'TODAY · WEEK ${session.week}'
                        : 'WEEK ${session.week}'
                              '${session.isDeload ? ' · DELOAD' : ''}',
                    style: t.labelSmall?.copyWith(
                      color: color,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(day.title, style: t.titleMedium),
                  Text(
                    compact ? sub : '${day.focus}\n$sub',
                    style: t.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null) const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _ExerciseTile extends StatelessWidget {
  const _ExerciseTile({required this.index, required this.plan});
  final int index;
  final ExercisePlan plan;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + 50 * index.clamp(0, 8)),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 12),
          child: child,
        ),
      ),
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        onTap: () => _showDetail(context),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: scheme.surfaceContainerHighest,
              child: Text('${index + 1}', style: t.labelMedium),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plan.name, style: t.titleSmall),
                  Text(
                    '${plan.sets} × ${plan.repRange} · RIR ${plan.rir}'
                    '${plan.restSeconds > 0 ? ' · rest ${_rest(plan.restSeconds)}' : ''}',
                    style: t.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (plan.note != null)
                    Text(
                      plan.note!,
                      style: t.bodySmall?.copyWith(color: AppColors.warning),
                    ),
                ],
              ),
            ),
            const Icon(Icons.info_outline, size: 18),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    final info = plan.info;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(plan.name, style: t.titleLarge),
              if (info != null) Text(info.muscle, style: t.labelLarge),
              const SizedBox(height: AppSpacing.md),
              Text(
                '${plan.sets} sets × ${plan.repRange} reps · leave '
                '${plan.rir} rep${plan.rir == 1 ? '' : 's'} in reserve · '
                'rest ${_rest(plan.restSeconds)}',
              ),
              if (info?.cue.isNotEmpty ?? false) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Cue: ${info!.cue}'),
              ],
              if (info?.substitute != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Swap if needed: ${info!.substitute}'),
              ],
              const SizedBox(height: AppSpacing.md),
              Text(TrainingProgram.progressionRule, style: t.bodySmall),
            ],
          ),
        );
      },
    );
  }
}

String _rest(int s) =>
    s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} min' : '$s s';

class _PaceZonesCard extends StatelessWidget {
  const _PaceZonesCard({required this.zones});
  final PaceZones zones;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget row(String label, (int, int) r, String note) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(child: Text(label, style: t.labelLarge)),
          Text(formatPaceRange(r.$1, r.$2), style: t.titleSmall),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(width: 92, child: Text(note, style: t.bodySmall)),
        ],
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pace zones (estimates)', style: t.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          row('Easy / Zone 2', zones.easy, 'conversational'),
          row('Tempo', zones.tempo, 'comfortably hard'),
          row('Intervals', zones.interval, 'hard, controlled'),
          row('Goal 5K', zones.goal, 'race pace'),
        ],
      ),
    );
  }
}

/// Compact "today's session" card for Today and Train. Renders nothing until
/// JARVIS calibration has created a program.
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
      onTap: () => context.push(AppPaths.program),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottomGap),
      child: hero ? Hero(tag: s.heroTag, child: card) : card,
    );
  }
}
