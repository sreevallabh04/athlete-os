import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../planning/application/planning_providers.dart';
import '../../planning/data/planning_repository.dart';
import '../../planning/presentation/widgets/countdown_hero.dart';
import '../application/today_providers.dart';
import '../data/today_repository.dart';
import '../domain/daily_summary.dart';
import 'today_widgets.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final date = LocalDates.key(now);
    final snapshot = ref.watch(todaySnapshotProvider);
    final calendar = ref.watch(calendarDayProvider(date));

    Future<void> refresh() async {
      ref.invalidate(todaySnapshotProvider);
      ref.invalidate(calendarDayProvider(date));
      await ref.read(todaySnapshotProvider.future);
    }

    return AppPage(
      title: 'Today',
      showBack: false,
      onRefresh: refresh,
      actions: [
        IconButton(
          tooltip: 'Plan your day',
          icon: const Icon(Icons.view_timeline_outlined),
          onPressed: () => context.push(AppPaths.planner),
        ),
        IconButton(
          tooltip: 'Reports',
          icon: const Icon(Icons.insights_outlined),
          onPressed: () => context.push(AppPaths.reports),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push(AppPaths.settings),
        ),
      ],
      children: [
        snapshot.when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
            message: 'Could not load today’s data.',
            onRetry: () => ref.invalidate(todaySnapshotProvider),
          ),
          data: (s) => _TodayBody(snapshot: s, calendar: calendar),
        ),
      ],
    );
  }
}

class _TodayBody extends StatelessWidget {
  const _TodayBody({required this.snapshot, required this.calendar});
  final TodaySnapshot snapshot;
  final AsyncValue<CalendarReadResult> calendar;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final summary = buildDailySummary(
      _summaryInput(
        s,
        calendar.value,
        pending: calendar.isLoading && !calendar.hasValue,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(snapshot: s),
        const SizedBox(height: AppSpacing.lg),
        if (s.competition != null)
          CountdownHero(
            view: s.competition!,
            onTap: () => context.push(AppPaths.competition),
          )
        else
          CompetitionCta(onTap: () => context.push(AppPaths.competition)),
        const SizedBox(height: AppSpacing.md),
        _SummaryCard(summary: summary),
        ResponsiveColumns(
          left: [
            const SectionHeader('Fitness'),
            _StepsCard(s: s),
            const SizedBox(height: AppSpacing.md),
            _FitnessTiles(s: s),
            const SectionHeader('Nutrition'),
            _NutritionCard(s: s),
            const SizedBox(height: AppSpacing.md),
            _WaterCard(s: s),
          ],
          right: [
            const SectionHeader('Productivity & well-being'),
            _CalendarCard(calendar: calendar, now: s.now),
            const SizedBox(height: AppSpacing.md),
            _PrioritiesCard(s: s),
            const SizedBox(height: AppSpacing.md),
            _CheckInsGrid(s: s),
          ],
        ),
      ],
    );
  }
}

SummaryInput _summaryInput(
  TodaySnapshot s,
  CalendarReadResult? cal, {
  bool pending = false,
}) {
  final p = s.profile;
  return SummaryInput(
    now: s.now,
    competitionHeadline: s.competition?.countdown.headline(
      s.competition!.competition.name,
    ),
    steps: s.steps == null
        ? null
        : StepsFact(
            steps: s.steps!.value.round(),
            goal: p.stepGoal,
            origin: s.steps!.origin,
            asOf: s.steps!.computedAt,
          ),
    nutrition: NutritionFact(
      entries: s.nutrition.entries,
      kcal: s.nutrition.kcal,
      proteinG: s.nutrition.proteinG,
      kcalTarget: p.calorieTarget,
      proteinTargetG: p.proteinTargetG,
    ),
    water: WaterFact(ml: s.waterMl, goalMl: p.waterGoalMl),
    calendarPending: pending,
    calendar: cal == null
        ? null
        : CalendarFact(
            connected: cal.connected,
            error: cal.error,
            events: [
              for (final e in cal.events)
                EventFact(title: e.title, start: e.start, allDay: e.allDay),
            ],
          ),
    plannedWorkout: s.plannedWorkout,
    completedWorkout: s.workoutToday == null
        ? null
        : (s.workoutToday!.title, s.workoutToday!.source),
    sleep: s.sleep == null
        ? null
        : SleepFact(
            minutes: s.sleep!.value.round(),
            origin: s.sleep!.origin,
            asOf: s.sleep!.computedAt,
          ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.snapshot});
  final TodaySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final h = snapshot.now.hour;
    final greeting = h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 17
        ? 'Good afternoon'
        : 'Good evening';
    final name = snapshot.profile.displayName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEEE, d MMMM').format(snapshot.now).toUpperCase(),
          style: t.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          name == null || name.isEmpty ? '$greeting.' : '$greeting, $name.',
          style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final DailySummary summary;

  static IconData _icon(SummaryTopic t) => switch (t) {
    SummaryTopic.competition => Icons.emoji_events_outlined,
    SummaryTopic.steps => Icons.directions_walk,
    SummaryTopic.protein => Icons.egg_alt_outlined,
    SummaryTopic.calories => Icons.local_fire_department_outlined,
    SummaryTopic.water => Icons.water_drop_outlined,
    SummaryTopic.calendar => Icons.event_outlined,
    SummaryTopic.workout => Icons.fitness_center,
    SummaryTopic.sleep => Icons.bedtime_outlined,
  };

  static Color _color(SummaryTopic t) => switch (t) {
    SummaryTopic.competition => AppColors.competition,
    SummaryTopic.steps => AppColors.steps,
    SummaryTopic.protein => AppColors.protein,
    SummaryTopic.calories => AppColors.calories,
    SummaryTopic.water => AppColors.water,
    SummaryTopic.calendar => AppColors.info,
    SummaryTopic.workout => AppColors.strength,
    SummaryTopic.sleep => AppColors.sleep,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      accent: AppColors.brand,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_motion,
                size: 18,
                color: AppColors.brand,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Your day so far', style: t.titleMedium)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (summary.lines.isEmpty)
            Text(
              'Nothing to summarise yet — log food, water or connect '
              'Health Connect to see a daily brief.',
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          for (final line in summary.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      _icon(line.topic),
                      size: 16,
                      color: _color(line.topic),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(line.text, style: t.bodyMedium)),
                ],
              ),
            ),
          if (summary.unavailable.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Not available yet',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final u in summary.unavailable) UnavailableChip(u),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Built from your logged and synced data only.',
            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.s});
  final TodaySnapshot s;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final steps = s.steps;
    final goal = s.profile.stepGoal;
    if (steps == null) {
      return AppCard(
        child: EmptyState(
          compact: true,
          icon: Icons.directions_walk,
          title: 'No step data yet today',
          message:
              'Steps appear here once Health Connect syncs or you add them '
              'manually.',
          actionLabel: 'Check Health Connect',
          onAction: () => context.push(AppPaths.healthStatus),
        ),
      );
    }
    final value = steps.value.round();
    final remaining = goal - value;
    return AppCard(
      accent: AppColors.steps,
      onTap: () => context.push(AppPaths.steps),
      child: Row(
        children: [
          ProgressRing(
            progress: goal <= 0 ? 0 : value / goal,
            color: AppColors.steps,
            size: 116,
            stroke: 11,
            semanticLabel: 'Steps $value of $goal',
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  Fmt.integer(value),
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  'of ${Fmt.integer(goal)}',
                  style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Steps', style: t.labelLarge),
                Text(
                  remaining > 0
                      ? '${Fmt.integer(remaining)} to go'
                      : 'Goal reached',
                  style: t.titleMedium?.copyWith(
                    color: remaining > 0 ? null : AppColors.success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.xs,
                  children: [
                    _inline(
                      context,
                      Icons.straighten,
                      s.distance == null ? '— km' : Fmt.km(s.distance!.value),
                    ),
                    _inline(
                      context,
                      Icons.timer_outlined,
                      s.activeMinutes == null
                          ? '— active min'
                          : '${s.activeMinutes!.value.round()} active min',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                SourceBadge(
                  origin: DataOrigin.fromKey(steps.origin),
                  asOf: steps.computedAt,
                  now: s.now,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inline(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _FitnessTiles extends StatelessWidget {
  const _FitnessTiles({required this.s});
  final TodaySnapshot s;

  @override
  Widget build(BuildContext context) {
    final w = s.latestWorkout;
    final runs = s.weekRuns;
    final sleep = s.sleep;
    final hr = s.latestHeartRate;
    return TileGrid(
      children: [
        MetricTile(
          icon: Icons.fitness_center,
          color: AppColors.strength,
          label: 'Latest workout',
          value: w?.title,
          sub: w == null
              ? null
              : '${Fmt.weekdayDayMonth(w.startAt)} · '
                    '${s.latestWorkoutExercises} exercises',
          badge: w == null
              ? null
              : SourceBadge(
                  origin: DataOrigin.fromKey(w.source),
                  asOf: w.endAt ?? w.startAt,
                  now: s.now,
                  staleAfter: const Duration(days: 365),
                ),
          emptyText: 'No workouts recorded yet',
          onTap: w == null
              ? () => context.push(AppPaths.strength)
              : () => context.push(
                  AppPaths.workoutDetail.replaceFirst(':id', w.id),
                ),
        ),
        MetricTile(
          icon: Icons.directions_run,
          color: AppColors.running,
          label: 'Running this week',
          value: runs.count == 0 ? null : Fmt.km(runs.distanceM),
          sub: runs.count == 0
              ? null
              : '${runs.count} run${runs.count == 1 ? '' : 's'} · '
                    'from ${_sources(runs.sources)}',
          emptyText: 'No runs since Monday',
          onTap: () => context.push(AppPaths.running),
        ),
        MetricTile(
          icon: Icons.bedtime_outlined,
          color: AppColors.sleep,
          label: 'Sleep last night',
          value: sleep == null
              ? null
              : '${sleep.value.round() ~/ 60} h ${sleep.value.round() % 60} m',
          badge: sleep == null
              ? null
              : SourceBadge(
                  origin: DataOrigin.fromKey(sleep.origin),
                  asOf: sleep.computedAt,
                  now: s.now,
                  staleAfter: const Duration(hours: 24),
                ),
          emptyText: 'No sleep data',
          onTap: () => context.push(AppPaths.healthOverview),
        ),
        MetricTile(
          icon: Icons.favorite_outline,
          color: AppColors.heart,
          label: 'Latest heart rate',
          value: hr == null ? null : '${hr.value.round()} bpm',
          sub: hr == null ? null : 'at ${Fmt.time(hr.endAt)}',
          badge: hr == null
              ? null
              : SourceBadge(
                  origin: DataOrigin.fromKey(hr.origin),
                  asOf: hr.endAt,
                  now: s.now,
                ),
          emptyText: 'No heart-rate data',
          onTap: () => context.push(AppPaths.healthOverview),
        ),
      ],
    );
  }

  static String _sources(Set<String> keys) =>
      keys.map((k) => DataOrigin.fromKey(k).label).join(' + ');
}

class _NutritionCard extends StatelessWidget {
  const _NutritionCard({required this.s});
  final TodaySnapshot s;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final n = s.nutrition;
    final p = s.profile;
    if (!n.logged) {
      return AppCard(
        child: EmptyState(
          compact: true,
          icon: Icons.restaurant_outlined,
          title: 'Nothing logged yet today',
          message:
              'Targets: ${Fmt.kcal(p.calorieTarget)} · '
              '${Fmt.grams(p.proteinTargetG.round())} protein.',
          actionLabel: 'Log food',
          onAction: () => context.push(AppPaths.nutrition),
        ),
      );
    }
    final kcalLeft = p.calorieTarget - n.kcal;
    final proteinLeft = p.proteinTargetG - n.proteinG;
    return AppCard(
      accent: AppColors.calories,
      onTap: () => context.push(AppPaths.nutrition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ProgressRing(
                progress: p.calorieTarget <= 0 ? 0 : n.kcal / p.calorieTarget,
                color: AppColors.calories,
                size: 116,
                stroke: 11,
                semanticLabel:
                    'Calories ${n.kcal.round()} of ${p.calorieTarget}',
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      Fmt.integer(n.kcal),
                      style: t.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'of ${Fmt.integer(p.calorieTarget)} kcal',
                      style: t.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  children: [
                    MetricBar(
                      label: 'Protein',
                      value: n.proteinG,
                      target: p.proteinTargetG,
                      color: AppColors.protein,
                      unit: ' g',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    MetricBar(
                      label: 'Carbs',
                      value: n.carbsG,
                      target: p.carbsTargetG,
                      color: AppColors.carbs,
                      unit: ' g',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    MetricBar(
                      label: 'Fat',
                      value: n.fatG,
                      target: p.fatTargetG,
                      color: AppColors.fat,
                      unit: ' g',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.sm,
            children: [
              StatTile(
                label: kcalLeft >= 0 ? 'Calories left' : 'Over target',
                value: Fmt.kcal(kcalLeft.abs()),
              ),
              StatTile(
                label: proteinLeft > 0 ? 'Protein to go' : 'Protein',
                value: proteinLeft > 0
                    ? Fmt.grams(proteinLeft.round())
                    : 'Target met',
              ),
              StatTile(
                label: 'Meals logged',
                value: '${s.mealsLogged}',
                sub: '${n.entries} items',
              ),
            ],
          ),
          if (s.nutritionLastLoggedAt != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'From your food log · last entry '
              '${Fmt.ago(s.nutritionLastLoggedAt!, s.now)}',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _WaterCard extends StatelessWidget {
  const _WaterCard({required this.s});
  final TodaySnapshot s;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final goal = s.profile.waterGoalMl;
    if (s.waterMl <= 0) {
      return AppCard(
        onTap: () => context.push(AppPaths.hydration),
        child: Row(
          children: [
            const Icon(Icons.water_drop_outlined, color: AppColors.water),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'No water logged today · goal ${Fmt.ml(goal)}',
                style: t.bodyMedium,
              ),
            ),
            Text('Log', style: t.labelLarge?.copyWith(color: AppColors.water)),
          ],
        ),
      );
    }
    return AppCard(
      accent: AppColors.water,
      onTap: () => context.push(AppPaths.hydration),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetricBar(
            label: 'Water',
            value: s.waterMl.toDouble(),
            target: goal.toDouble(),
            color: AppColors.water,
            formatter: (v) => Fmt.ml(v),
          ),
          if (s.waterLastLoggedAt != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Last logged ${Fmt.ago(s.waterLastLoggedAt!, s.now)}',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _CalendarCard extends StatelessWidget {
  const _CalendarCard({required this.calendar, required this.now});
  final AsyncValue<CalendarReadResult> calendar;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_outlined, size: 18, color: AppColors.info),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Calendar', style: t.titleSmall)),
              TextButton(
                onPressed: () => context.push(AppPaths.planner),
                child: const Text('Plan day'),
              ),
            ],
          ),
          calendar.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: LinearProgressIndicator(),
            ),
            error: (e, _) =>
                Text('Could not load calendar events.', style: t.bodyMedium),
            data: (r) {
              if (!r.connected) {
                return NoticeBanner(
                  message: 'Google Calendar is not connected.',
                  icon: Icons.link_off,
                  actionLabel: 'Connect',
                  onAction: () => context.push(AppPaths.integrations),
                );
              }
              if (r.error != null) {
                return const NoticeBanner(
                  message: 'Calendar could not be loaded right now.',
                  icon: Icons.cloud_off,
                  color: AppColors.warning,
                );
              }
              final events = [...r.events]
                ..sort((a, b) => a.start.compareTo(b.start));
              if (events.isEmpty) {
                return Text(
                  'No events today.',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                );
              }
              return Column(
                children: [
                  for (final e in events.take(5))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 72,
                            child: Text(
                              e.allDay ? 'All day' : Fmt.time(e.start),
                              style: t.labelMedium?.copyWith(
                                color: e.end.isBefore(now)
                                    ? scheme.onSurfaceVariant
                                    : AppColors.info,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.title,
                              style: t.bodyMedium?.copyWith(
                                color: e.end.isBefore(now)
                                    ? scheme.onSurfaceVariant
                                    : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (events.length > 5)
                    Text('+${events.length - 5} more', style: t.labelSmall),
                  if (r.fetchedAt != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SourceBadge(
                        origin: DataOrigin.googleCalendar,
                        asOf: r.fetchedAt,
                        now: now,
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

class _PrioritiesCard extends ConsumerWidget {
  const _PrioritiesCard({required this.s});
  final TodaySnapshot s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined, size: 18, color: AppColors.brand),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Top priorities', style: t.titleSmall)),
              if (s.taskCount > 0)
                Text(
                  '${s.tasksDone}/${s.taskCount} done',
                  style: t.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (s.topTasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                'No priorities set for today.',
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final task in s.topTasks)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: task.done,
              onChanged: (v) => ref
                  .read(planningRepositoryProvider)
                  .setTaskDone(task.id, v ?? false),
              title: Text(
                task.title,
                style: t.bodyLarge?.copyWith(
                  decoration: task.done ? TextDecoration.lineThrough : null,
                  color: task.done ? scheme.onSurfaceVariant : null,
                ),
              ),
              subtitle: task.project == null ? null : Text(task.project!),
              secondary: _PriorityDot(priority: task.priority),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => context.push(AppPaths.planner),
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                s.topTasks.isEmpty ? 'Add priorities' : 'Open planner',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PriorityDot extends StatelessWidget {
  const _PriorityDot({required this.priority});
  final int priority;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      1 => AppColors.danger,
      2 => AppColors.warning,
      _ => AppColors.info,
    };
    return Semantics(
      label: 'Priority $priority',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: AppRadii.chip,
        ),
        child: Text(
          'P$priority',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _CheckInsGrid extends StatelessWidget {
  const _CheckInsGrid({required this.s});
  final TodaySnapshot s;

  static const _moodLabels = ['Awful', 'Low', 'Okay', 'Good', 'Great'];

  @override
  Widget build(BuildContext context) {
    final tally = s.habitTally;
    final mood = s.moodToday;
    return TileGrid(
      children: [
        MetricTile(
          icon: Icons.check_circle_outline,
          color: AppColors.habit,
          label: 'Habits today',
          value: s.habitCount == 0 || tally.total == 0
              ? null
              : '${tally.done} of ${tally.total} done',
          sub: tally.total == 0
              ? null
              : tally.remaining == 0
              ? 'All done'
              : '${tally.remaining} remaining',
          emptyText: s.habitCount == 0
              ? 'No habits set up'
              : 'Nothing scheduled today',
          onTap: () => context.push(AppPaths.habits),
        ),
        MetricTile(
          icon: Icons.mood,
          color: AppColors.mood,
          label: 'Mood check-in',
          value: mood == null
              ? null
              : '${_moodLabels[(mood.mood - 1).clamp(0, 4)]} (${mood.mood}/5)',
          sub: mood == null ? null : 'Logged ${Fmt.time(mood.recordedAt)}',
          emptyText: 'Not checked in yet',
          onTap: () => context.push(AppPaths.mood),
        ),
        MetricTile(
          icon: Icons.menu_book_outlined,
          color: AppColors.sleep,
          label: 'Journal',
          value: s.journalToday ? 'Written today' : null,
          emptyText: 'No entry yet today',
          onTap: () => context.push(AppPaths.journal),
        ),
        MetricTile(
          icon: Icons.insights_outlined,
          color: AppColors.brandAlt,
          label: 'Reports',
          value: 'Weekly & monthly',
          sub: 'Generated from your data',
          onTap: () => context.push(AppPaths.reports),
        ),
      ],
    );
  }
}
