import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import '../domain/habit_models.dart';
import 'habit_detail_screen.dart';
import 'habit_editor_screen.dart';
import 'manage_habits_screen.dart';
import 'suggested_habits_sheet.dart';
import 'widgets/life_widgets.dart';

class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(habitBoardProvider);
    final suggestions =
        ref.watch(pendingHabitSuggestionsProvider).value ?? const [];
    return AppPage(
      title: 'Habits',
      actions: [
        IconButton(
          tooltip: 'Suggested habits',
          icon: const Icon(Icons.lightbulb_outline),
          onPressed: () => showSuggestedHabitsSheet(context),
        ),
        IconButton(
          tooltip: 'Manage and reorder',
          icon: const Icon(Icons.tune),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ManageHabitsScreen()),
          ),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-habit',
        onPressed: () => openHabitEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('New habit'),
      ),
      children: board.when(
        loading: () => const [LoadingState()],
        error: (e, _) => [
          ErrorState(
            message: 'Your habits couldn\'t be loaded.',
            onRetry: () => ref.invalidate(habitBoardProvider),
          ),
        ],
        data: (b) => [
          for (final s in suggestions) ...[
            AiHabitSuggestionCard(suggestion: s),
            const SizedBox(height: AppSpacing.md),
          ],
          if (b.habits.isEmpty)
            _EmptyHabits()
          else ...[
            _TodaySummary(board: b),
            SectionHeader(
              'Today',
              subtitle: DateFormat('EEEE, d MMMM')
                  .format(LocalDates.parse(b.today)),
            ),
            if (b.dueToday.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.event_available_outlined,
                title: 'Nothing scheduled today',
                message: 'Enjoy the space.',
              )
            else
              ...spaced([
                for (final h in b.dueToday) HabitTodayTile(view: h),
              ], gap: AppSpacing.sm),
            if (b.notDueToday.isNotEmpty) ...[
              const SectionHeader(
                'Not due today',
                subtitle: 'Weekly targets already met or other days',
              ),
              ...spaced([
                for (final h in b.notDueToday)
                  HabitTodayTile(view: h, muted: true),
              ], gap: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class _EmptyHabits extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: [
          const EmptyState(
            icon: Icons.checklist_rtl,
            title: 'No habits yet',
            message:
                'Start with one or two that fit your day. Skipping a day is '
                'always allowed.',
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => openHabitEditor(context),
                  child: const Text('Create your own'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: FilledButton(
                  onPressed: () => showSuggestedHabitsSheet(context),
                  child: const Text('Add suggested'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TodaySummary extends StatelessWidget {
  const _TodaySummary({required this.board});
  final HabitBoard board;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final due = board.dueToday.length;
    final done = board.doneToday;
    final week = board.weekTotal;
    final rate = week.rate;
    return AppCard(
      accent: AppColors.habit,
      semanticLabel:
          '$done of $due habits done today, ${board.remainingToday} remaining',
      child: Row(
        children: [
          ProgressRing(
            progress: due == 0 ? 0 : done / due,
            color: AppColors.habit,
            size: 84,
            stroke: 9,
            center: Text('$done/$due', style: t.titleMedium),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  board.remainingToday == 0 && due > 0
                      ? 'All set for today'
                      : '${board.remainingToday} remaining today',
                  style: t.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  rate == null
                      ? 'This week: nothing due yet'
                      : 'This week: ${(rate * 100).round()}% '
                            '(${week.done} of ${week.due})',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (week.skipped > 0)
                  Text(
                    '${week.skipped} skipped — not counted',
                    style: t.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One habit in today's checklist: one-tap complete, skip from the menu,
/// undo by tapping again.
class HabitTodayTile extends ConsumerWidget {
  const HabitTodayTile({super.key, required this.view, this.muted = false});
  final HabitView view;
  final bool muted;

  Future<void> _set(
    BuildContext context,
    WidgetRef ref,
    HabitStatus? status,
  ) async {
    final repo = ref.read(habitRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final today = LocalDates.key(ref.read(clockProvider).now());
    final previous = view.marks[today];
    if (status == null) {
      await repo.clearStatus(view.id, today);
    } else {
      await repo.setStatus(view.id, today, status);
    }
    if (status == HabitStatus.skipped) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('${view.name} skipped today. No penalty.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              if (previous == null || previous.auto) {
                await repo.clearStatus(view.id, today);
              } else {
                await repo.setStatus(view.id, today, previous.status);
              }
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final mark = view.todayMark;
    final isDone = mark?.isDone ?? false;
    final isSkipped = mark?.isSkipped ?? false;
    final isAuto = mark?.auto ?? false;

    final (IconData icon, Color color, String action) = isDone
        ? (
            Icons.check_circle,
            AppColors.habit,
            isAuto
                ? '${view.name} completed automatically'
                : 'Undo ${view.name}',
          )
        : isSkipped
        ? (
            Icons.remove_circle_outline,
            scheme.onSurfaceVariant,
            'Undo skip for ${view.name}',
          )
        : (
            Icons.radio_button_unchecked,
            scheme.onSurfaceVariant,
            'Mark ${view.name} done',
          );

    final streak = view.streak;
    final details = <Widget>[
      if (view.schedule.isWeekly)
        Text(
          '${view.weekDone}/${view.schedule.weeklyTarget} this week',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      if (streak.current > 0)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.local_fire_department_outlined,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Text(
              streak.format(streak.current),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      if (isAuto)
        const TagPill('auto', color: AppColors.info, icon: Icons.bolt),
      if (isSkipped) const TagPill('skipped'),
      if (view.upNext)
        const TagPill('Up next', color: AppColors.habit, icon: Icons.east),
      if (!view.upNext && mark == null && view.dependsOnName != null)
        TagPill('after ${view.dependsOnName}'),
      if (muted && !view.schedule.isWeekly)
        Text(
          view.schedule.describe(),
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
    ];

    return Opacity(
      opacity: muted ? 0.7 : 1,
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xs,
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => HabitDetailScreen(habitId: view.id),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              key: Key('habit-check-${view.id}'),
              iconSize: 30,
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              tooltip: action,
              icon: AnimatedSwitcher(
                duration: AppDurations.fast,
                child: Icon(icon, key: ValueKey(icon), color: color),
              ),
              onPressed: () {
                if (isAuto) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Completed automatically from your logged data. '
                        'Use the menu if you want to mark it differently.',
                      ),
                    ),
                  );
                  return;
                }
                _set(context, ref, mark == null ? HabitStatus.done : null);
              },
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.name,
                      style: t.titleMedium?.copyWith(
                        color: isSkipped ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: details,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More for ${view.name}',
              onSelected: (v) async {
                switch (v) {
                  case 'done':
                    await _set(context, ref, HabitStatus.done);
                  case 'skip':
                    await _set(context, ref, HabitStatus.skipped);
                  case 'undo':
                    await _set(context, ref, null);
                  case 'edit':
                    if (context.mounted) {
                      await openHabitEditor(context, habit: view.habit);
                    }
                }
              },
              itemBuilder: (_) => [
                if (!isDone || isAuto)
                  const PopupMenuItem(value: 'done', child: Text('Mark done')),
                if (!isSkipped)
                  const PopupMenuItem(value: 'skip', child: Text('Skip today')),
                if (mark != null && !isAuto)
                  const PopupMenuItem(value: 'undo', child: Text('Undo')),
                const PopupMenuItem(value: 'edit', child: Text('Edit habit')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pending AI habit suggestion with Accept / Edit / Dismiss.
class AiHabitSuggestionCard extends ConsumerWidget {
  const AiHabitSuggestionCard({super.key, required this.suggestion});
  final AiRecommendation suggestion;

  String get _suggestedName {
    final firstLine = suggestion.content.trim().split('\n').first;
    return firstLine.length > 60 ? firstLine.substring(0, 60) : firstLine;
  }

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: _suggestedName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add as a habit'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Habit name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add habit'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final repo = ref.read(habitRepositoryProvider);
    await repo.create(HabitInput(name: name, notes: suggestion.content));
    await repo.respondToSuggestion(
      suggestion.id,
      name == _suggestedName ? 'accepted' : 'edited',
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final id = await openHabitEditor(
      context,
      initialName: _suggestedName,
      initialNotes: suggestion.content,
    );
    if (id != null) {
      await ref
          .read(habitRepositoryProvider)
          .respondToSuggestion(suggestion.id, 'edited');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      accent: AppColors.brand,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text('Suggested by your AI coach', style: t.labelLarge),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(suggestion.content, style: t.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              TextButton(
                onPressed: () => ref
                    .read(habitRepositoryProvider)
                    .respondToSuggestion(suggestion.id, 'dismissed'),
                child: const Text('Dismiss'),
              ),
              OutlinedButton(
                onPressed: () => _edit(context, ref),
                child: const Text('Edit'),
              ),
              FilledButton(
                onPressed: () => _accept(context, ref),
                child: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens the habit editor. Returns the saved habit id (or null).
Future<String?> openHabitEditor(
  BuildContext context, {
  Habit? habit,
  String? initialName,
  String? initialNotes,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => HabitEditorScreen(
      habit: habit,
      initialName: initialName,
      initialNotes: initialNotes,
    ),
  ),
);

/// Short label for a streak + week stat used in several places.
String habitStatsLine(HabitView v) {
  final rate = v.week.rate;
  final parts = <String>[
    v.streak.format(v.streak.current),
    if (rate != null) '${(rate * 100).round()}% this week',
  ];
  return parts.join(' · ');
}
