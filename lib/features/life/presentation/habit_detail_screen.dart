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
    final today = LocalDates.key(ref.watch(clockProvider).now());
    return async.when(
      loading: () => const AppPage(title: 'Habit', children: [LoadingState()]),
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
        String pct(double? r) => r == null ? '–' : '${(r * 100).round()}%';
        return AppPage(
          title: v.name,
          subtitle: [
            v.schedule.describe(),
            if (v.habit.archived) 'Archived',
          ].join(' · '),
          actions: [
            IconButton(
              tooltip: 'Edit habit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => openHabitEditor(context, habit: v.habit),
            ),
          ],
          children: [
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: StatTile(
                          label: 'Current streak',
                          value: v.streak.format(v.streak.current),
                          icon: Icons.local_fire_department_outlined,
                          color: AppColors.habit,
                        ),
                      ),
                      Expanded(
                        child: StatTile(
                          label: 'Best streak',
                          value: v.streak.format(v.streak.best),
                          icon: Icons.emoji_events_outlined,
                          color: AppColors.habit,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: StatTile(
                          label: 'This week',
                          value: pct(v.week.rate),
                          sub: v.schedule.isWeekly
                              ? '${v.weekDone} of ${v.schedule.weeklyTarget}'
                              : '${v.week.done} of ${v.week.due} due',
                        ),
                      ),
                      Expanded(
                        child: StatTile(
                          label: 'Last 30 days',
                          value: pct(last30.rate),
                          sub:
                              '${last30.done} of ${last30.due}'
                              '${last30.skipped > 0 ? ' · ${last30.skipped} skipped' : ''}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Skipped days are neutral: they never break a streak or '
                    'lower your percentage.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SectionHeader(
              DateFormat('MMMM yyyy').format(_month),
              subtitle: 'Tap a day to change it',
            ),
            AppCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous month',
                        onPressed: () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month - 1),
                        ),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Next month',
                        onPressed:
                            DateTime(
                              _month.year,
                              _month.month + 1,
                            ).isAfter(LocalDates.parse(today))
                            ? null
                            : () => setState(
                                () => _month = DateTime(
                                  _month.year,
                                  _month.month + 1,
                                ),
                              ),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  HabitMonthHeatmap(
                    view: v,
                    month: _month,
                    today: today,
                    onDayTap: (d) => _editDay(context, v, d),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const _Legend(),
                ],
              ),
            ),
            const SectionHeader('Details'),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: spaced([
                  _InfoRow(
                    'Category',
                    HabitCategory.fromKey(v.habit.category).label,
                  ),
                  _InfoRow(
                    'Reminders',
                    v.reminderTimes.isEmpty
                        ? 'None'
                        : v.reminderTimes.map(formatMinutes).join(', '),
                  ),
                  _InfoRow('Automatic', v.autoRule?.label ?? 'Off'),
                  if (v.dependsOnName != null)
                    _InfoRow('After', v.dependsOnName!),
                  if (v.habit.notes != null) _InfoRow('Notes', v.habit.notes!),
                ]),
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                DateFormat('EEEE, d MMMM').format(LocalDates.parse(date)),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            if (mark?.auto ?? false)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text('Completed automatically from logged data.'),
              ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: AppColors.habit),
              title: const Text('Done'),
              onTap: () => Navigator.pop(ctx, 'done'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Skipped'),
              subtitle: const Text('Neutral — doesn\'t affect streaks'),
              onTap: () => Navigator.pop(ctx, 'skipped'),
            ),
            if (mark != null && !mark.auto)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('Clear'),
                onTap: () => Navigator.pop(ctx, 'clear'),
              ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'done':
        await repo.setStatus(v.id, date, HabitStatus.done);
      case 'skipped':
        await repo.setStatus(v.id, date, HabitStatus.skipped);
      case 'clear':
        await repo.clearStatus(v.id, date);
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: t.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value, style: t.bodyMedium)),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget item(Color fill, String label, {Color? border}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(3),
            border: border == null ? null : Border.all(color: border),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        item(AppColors.habit, 'Done'),
        item(AppColors.habit.withValues(alpha: 0.45), 'Auto'),
        item(Colors.transparent, 'Skipped', border: scheme.onSurfaceVariant),
        item(scheme.surfaceContainerHighest, 'Open'),
      ],
    );
  }
}

/// Month grid (Mon–Sun columns) colour-coded by day status.
class HabitMonthHeatmap extends StatelessWidget {
  const HabitMonthHeatmap({
    super.key,
    required this.view,
    required this.month,
    required this.today,
    required this.onDayTap,
  });

  final HabitView view;
  final DateTime month;
  final String today;
  final ValueChanged<String> onDayTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = first.weekday - 1;
    final cells = <Widget>[
      for (final l in weekdayLetter)
        Center(
          child: Text(
            l,
            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      for (var i = 0; i < leading; i++) const SizedBox.shrink(),
    ];
    for (var d = 1; d <= daysInMonth; d++) {
      final key = LocalDates.key(DateTime(month.year, month.month, d));
      final mark = view.marks[key];
      final future = key.compareTo(today) > 0;
      final scheduled = view.schedule.isScheduledDay(key);
      final beforeStart = key.compareTo(view.startDate) < 0 && mark == null;
      Color fill = Colors.transparent;
      Color? border;
      Color textColor = scheme.onSurface;
      String status;
      if (mark?.isDone ?? false) {
        fill = mark!.auto
            ? AppColors.habit.withValues(alpha: 0.45)
            : AppColors.habit;
        textColor = Colors.black;
        status = mark.auto ? 'done automatically' : 'done';
      } else if (mark?.isSkipped ?? false) {
        border = scheme.onSurfaceVariant;
        status = 'skipped';
      } else if (future || beforeStart || !scheduled) {
        textColor = scheme.onSurfaceVariant.withValues(alpha: 0.6);
        status = future ? 'upcoming' : 'not scheduled';
      } else {
        fill = scheme.surfaceContainerHighest;
        status = 'open';
      }
      if (key == today) border = scheme.primary;
      cells.add(
        Semantics(
          button: !future,
          label:
              '${DateFormat('d MMMM').format(LocalDates.parse(key))}, $status',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            onTap: future ? null : () => onDayTap(key),
            child: Container(
              margin: const EdgeInsets.all(2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: border == null
                    ? null
                    : Border.all(color: border, width: 1.5),
              ),
              child: Text(
                '$d',
                style: t.labelMedium?.copyWith(color: textColor),
              ),
            ),
          ),
        ),
      );
    }
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1,
      children: cells,
    );
  }
}
