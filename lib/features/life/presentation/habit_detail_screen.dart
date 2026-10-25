import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import '../domain/habit_engine.dart';
import '../domain/habit_models.dart';
import 'habits_screen.dart';
import 'widgets/habit_widgets.dart';
import 'widgets/life_widgets.dart';

export 'widgets/habit_widgets.dart' show HabitMonthHeatmap;

class HabitDetailScreen extends ConsumerStatefulWidget {
  const HabitDetailScreen({super.key, required this.habitId});
  final String habitId;

  @override
  ConsumerState<HabitDetailScreen> createState() => _HabitDetailScreenState();
}

class _HabitDetailScreenState extends ConsumerState<HabitDetailScreen> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider).now();
    _month = DateTime(now.year, now.month);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(habitDetailProvider(widget.habitId));
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    return async.when(
      loading: () => const AppPage(
        title: 'Habit',
        children: [ScanlineLoader(height: 160, lines: 0)],
      ),
      error: (e, _) => AppPage(
        title: 'Habit',
        children: [
          ErrorState(
            message: 'This habit couldn\'t be loaded.',
            onRetry: () => ref.invalidate(habitDetailProvider(widget.habitId)),
          ),
        ],
      ),
      data: (v) {
        if (v == null) {
          return const AppPage(
            title: 'Habit',
            children: [
              EmptyState(icon: Icons.delete_outline, title: 'Habit deleted'),
            ],
          );
        }
        final last30 = HabitEngine.completion(
          schedule: v.schedule,
          marks: v.marks,
          from: LocalDates.addDays(today, -29),
          to: today,
          today: today,
          startDate: v.startDate,
        );
        return AppPage(
          title: v.name,
          eyebrow: [
            v.schedule.describe().toUpperCase(),
            HabitCategory.fromKey(v.habit.category).label.toUpperCase(),
            if (v.habit.archived) 'ARCHIVED',
          ].join(' · '),
          actions: [
            IconButton(
              tooltip: 'Edit habit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => openHabitEditor(context, habit: v.habit),
            ),
          ],
          children: [
            _Hero(view: v, last30: last30, today: today),
            const LifeSection(
              'History',
              hint: 'Tap a day to change it · swipe for other months',
              accent: AppColors.habit,
            ),
            AppCard(
              child: Column(
                children: [
                  MonthSwitcher(
                    month: _month,
                    maxMonth: DateTime(now.year, now.month),
                    onChanged: (m) => setState(() => _month = m),
                    builder: (context) => HabitMonthHeatmap(
                      view: v,
                      month: _month,
                      today: today,
                      onDayTap: (d) => _editDay(context, v, d),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const HabitHeatmapLegend(),
                ],
              ),
            ),
            const SectionHeader('Details'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: spaced([
                  _InfoRow(
                    Icons.category_outlined,
                    'Category',
                    HabitCategory.fromKey(v.habit.category).label,
                  ),
                  _InfoRow(
                    Icons.alarm,
                    'Reminders',
                    v.reminderTimes.isEmpty
                        ? 'None'
                        : v.reminderTimes.map(formatMinutes).join(' · '),
                    mono: v.reminderTimes.isNotEmpty,
                  ),
                  _InfoRow(Icons.bolt, 'Automatic', v.autoRule?.label ?? 'Off'),
                  if (v.dependsOnName != null)
                    _InfoRow(Icons.east, 'After', v.dependsOnName!),
                  if (v.habit.notes != null)
                    _InfoRow(Icons.notes, 'Notes', v.habit.notes!),
                ], gap: AppSpacing.md),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editDay(BuildContext context, HabitView v, String date) async {
    final repo = ref.read(habitRepositoryProvider);
    final mark = v.marks[date];
    final choice = await showHudBottomSheet<String>(
      context,
      title: DateFormat('EEEE, d MMMM').format(LocalDates.parse(date)),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mark?.auto ?? false) ...[
            const NoticeBanner(
              icon: Icons.bolt,
              message: 'Completed automatically from logged data.',
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          _DayOption(
            node: HabitNodeState.done,
            title: 'Done',
            selected: (mark?.isDone ?? false) && !(mark?.auto ?? false),
            onTap: () => Navigator.pop(ctx, 'done'),
          ),
          const SizedBox(height: AppSpacing.sm),
          _DayOption(
            node: HabitNodeState.skipped,
            title: 'Skipped',
            subtitle: 'Neutral — doesn\'t affect streaks',
            selected: mark?.isSkipped ?? false,
            onTap: () => Navigator.pop(ctx, 'skipped'),
          ),
          if (mark != null && !mark.auto) ...[
            const SizedBox(height: AppSpacing.sm),
            _DayOption(
              node: HabitNodeState.open,
              title: 'Clear',
              subtitle: 'Back to no mark',
              selected: false,
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
          ],
        ],
      ),
    );
    switch (choice) {
      case 'done':
        Haptics.success();
        await repo.setStatus(v.id, date, HabitStatus.done);
      case 'skipped':
        Haptics.medium();
        await repo.setStatus(v.id, date, HabitStatus.skipped);
      case 'clear':
        Haptics.light();
        await repo.clearStatus(v.id, date);
    }
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.view, required this.last30, required this.today});
  final HabitView view;
  final CompletionStats last30;
  final String today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final v = view;
    final hot = isHotStreak(v.streak);
    final unitWord = v.streak.unit == StreakUnit.weeks ? 'WEEK' : 'DAY';
    String pct(double? r) => r == null ? '–' : '${(r * 100).round()}%';
    return AppCard(
      accent: hot ? AppColors.gold : AppColors.habit,
      brackets: true,
      glow: hot,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Hero(
                tag: 'habit-node-${v.id}',
                child: HabitCheckNode(
                  state: nodeStateOf(v.todayMark),
                  size: 54,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: 30,
                          color: hot ? AppColors.gold : hud.textMuted,
                          shadows: hot
                              ? AppGlows.text(
                                  AppColors.gold,
                                  strength: hud.glowStrength,
                                )
                              : null,
                        ),
                        const SizedBox(width: 4),
                        AnimatedTicker(
                          '${v.streak.current}',
                          style: hud.number(size: 48),
                        ),
                      ],
                    ),
                    Text(
                      '$unitWord STREAK · BEST ${v.streak.best}',
                      style: hud.label(size: 11),
                    ),
                  ],
                ),
              ),
              ArcGauge(
                value: last30.rate ?? 0,
                valueText: pct(last30.rate),
                label: '30 DAYS',
                color: AppColors.habit,
                width: 104,
                stroke: 7,
                semanticLabel: 'Last 30 days completion',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: StatTile(
                  label: 'This week',
                  value: pct(v.week.rate),
                  sub: v.schedule.isWeekly
                      ? '${v.weekDone} of ${v.schedule.weeklyTarget}'
                      : '${v.week.done} of ${v.week.due} due',
                  color: AppColors.habit,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Last 30 days',
                  value: '${last30.done}/${last30.due}',
                  sub: last30.skipped > 0
                      ? '${last30.skipped} skipped'
                      : 'no skips',
                  color: AppColors.habit,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Since',
                  value: DateFormat('d MMM')
                      .format(LocalDates.parse(v.startDate)),
                  sub:
                      '${LocalDates.parse(today).difference(LocalDates.parse(v.startDate)).inDays + 1} days',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(Icons.verified_outlined, size: 14, color: hud.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Skipped days are neutral: they never break a streak or '
                  'lower your percentage.',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayOption extends StatelessWidget {
  const _DayOption({
    required this.node,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });
  final HabitNodeState node;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        child: GlassPanel(
          accent: selected ? AppColors.habit : null,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
          child: HudRow(
            leading: HabitCheckNode(state: node, size: 34),
            title: title,
            subtitle: subtitle,
            trailing: selected
                ? const Icon(Icons.check, color: AppColors.habit, size: 18)
                : null,
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.label, this.value, {this.mono = false});
  final IconData icon;
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: hud.textMuted),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 96,
          child: Text(label.toUpperCase(), style: hud.label(size: 11)),
        ),
        Expanded(
          child: Text(
            value,
            style: mono ? hud.mono(size: 13, color: hud.text) : t.bodyMedium,
          ),
        ),
      ],
    );
  }
}
