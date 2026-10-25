import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import '../domain/habit_engine.dart';
import '../domain/habit_models.dart';
import 'habit_detail_screen.dart';
import 'habit_editor_screen.dart';
import 'manage_habits_screen.dart';
import 'suggested_habits_sheet.dart';
import 'widgets/habit_widgets.dart';
import 'widgets/life_widgets.dart';

class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(habitBoardProvider);
    final suggestions =
        ref.watch(pendingHabitSuggestionsProvider).value ?? const [];
    final now = ref.watch(clockProvider).now();
    final b = board.value;
    return AppPage(
      title: 'Habits',
      eyebrow: [
        DateFormat('EEE d MMM').format(now).toUpperCase(),
        if (b != null && b.dueToday.isNotEmpty)
          '${b.doneToday} OF ${b.dueToday.length} DONE',
      ].join(' · '),
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
      floatingActionButton: b == null || b.habits.isEmpty
          ? null
          : HudButton(
              label: 'New habit',
              icon: Icons.add,
              onPressed: () => openHabitEditor(context),
            ),
      children: board.when(
        loading: () => const [ScanlineLoader(height: 120, lines: 0)],
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
            const _EmptyHabits()
          else ...[
            _TodaySummary(board: b),
            LifeSection(
              'Today',
              hint: DateFormat('EEEE, d MMMM')
                  .format(LocalDates.parse(b.today)),
              accent: AppColors.habit,
            ),
            if (b.dueToday.isEmpty)
              const AppCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.event_available_outlined,
                  color: AppColors.habit,
                  title: 'Nothing scheduled today',
                  message: 'Enjoy the space.',
                ),
              )
            else
              StaggeredList(
                gap: AppSpacing.sm,
                children: [
                  for (final h in b.dueToday)
                    HabitTodayTile(key: ValueKey(h.id), view: h),
                ],
              ),
            if (b.notDueToday.isNotEmpty) ...[
              const LifeSection(
                'Not due today',
                hint: 'Weekly targets already met or other days',
              ),
              StaggeredList(
                gap: AppSpacing.sm,
                children: [
                  for (final h in b.notDueToday)
                    HabitTodayTile(key: ValueKey(h.id), view: h, muted: true),
                ],
              ),
            ],
            const SizedBox(height: 96),
          ],
        ],
      ),
    );
  }
}

class _EmptyHabits extends StatelessWidget {
  const _EmptyHabits();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      accent: AppColors.habit,
      brackets: true,
      child: Column(
        children: [
          const EmptyState(
            icon: Icons.checklist_rtl,
            color: AppColors.habit,
            eyebrow: 'STANDBY',
            title: 'No habits yet',
            message:
                'Start with one or two that fit your day. Skipping a day is '
                'always allowed.',
          ),
          HudButton(
            label: 'Add suggested',
            icon: Icons.lightbulb_outline,
            expand: true,
            onPressed: () => showSuggestedHabitsSheet(context),
          ),
          const SizedBox(height: AppSpacing.sm),
          HudButton.secondary(
            label: 'Create your own',
            icon: Icons.edit_outlined,
            expand: true,
            onPressed: () => openHabitEditor(context),
          ),
          const SizedBox(height: AppSpacing.xl),
          const Align(
            alignment: Alignment.centerLeft,
            child: HabitQuickStart(count: 6),
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
    final hud = context.hud;
    final due = board.dueToday.length;
    final done = board.doneToday;
    final week = board.weekTotal;
    final rate = week.rate;
    return AppCard(
      accent: AppColors.habit,
      brackets: true,
      semanticLabel:
          '$done of $due habits done today, ${board.remainingToday} remaining',
      child: Column(
        children: [
          Row(
            children: [
              ProgressRing(
                progress: due == 0 ? 0 : done / due,
                color: AppColors.habit,
                size: 92,
                stroke: 8,
                celebrate: false,
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedTicker('$done/$due', style: hud.number(size: 26)),
                    Text('TODAY', style: hud.label(size: 9.5)),
                  ],
                ),
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
                      style: t.bodyMedium?.copyWith(color: hud.textMuted),
                    ),
                    if (week.skipped > 0)
                      Text(
                        '${week.skipped} skipped — not counted',
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _WeekBars(board: board),
        ],
      ),
    );
  }
}

/// Completion across all habits for the last seven days (done ÷ due, skips
/// excluded), as luminous columns.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.board});
  final HabitBoard board;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    const c = AppColors.habit;
    final today = board.today;
    final days = [for (var i = 6; i >= 0; i--) LocalDates.addDays(today, -i)];
    final stats = [
      for (final d in days)
        board.habits.fold(
          CompletionStats.zero,
          (CompletionStats a, h) =>
              a +
              HabitEngine.completion(
                schedule: h.schedule,
                marks: h.marks,
                from: d,
                to: d,
                today: today,
                startDate: h.startDate,
              ),
        ),
    ];
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label:
          'Last 7 days: ${[for (var i = 0; i < 7; i++) '${DateFormat('EEEE').format(LocalDates.parse(days[i]))} ${stats[i].done} of ${stats[i].due}'].join(', ')}',
      excludeSemantics: true,
      child: SizedBox(
        height: 58,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final r = stats[i].rate ?? 0;
                            return Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: hud.hairline.withValues(
                                      alpha: hud.isDark ? 0.06 : 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: r),
                                  duration: reduced
                                      ? Duration.zero
                                      : AppMotion.data +
                                            AppMotion.staggerStep * i,
                                  curve: AppMotion.emphasizedDecelerate,
                                  builder: (context, v, _) => Container(
                                    height: box.maxHeight * v,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(3),
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          c.withValues(alpha: 0.35),
                                          c.withValues(alpha: r >= 1 ? 1 : 0.8),
                                        ],
                                      ),
                                      boxShadow: r >= 1
                                          ? [
                                              BoxShadow(
                                                color: c.withValues(
                                                  alpha:
                                                      0.35 * hud.glowStrength,
                                                ),
                                                blurRadius: 8,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        weekdayLetter[LocalDates.parse(days[i]).weekday - 1],
                        style: hud.label(
                          size: 10,
                          color: i == 6 ? hud.accentInk : hud.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One habit in today's checklist: tap the node to complete (tap again to
/// undo), hold it to skip, menu for everything else. Tapping the row opens
/// the habit's detail.
class HabitTodayTile extends ConsumerWidget {
  const HabitTodayTile({super.key, required this.view, this.muted = false});
  final HabitView view;
  final bool muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final mark = view.todayMark;
    final isDone = mark?.isDone ?? false;
    final isSkipped = mark?.isSkipped ?? false;
    final isAuto = mark?.auto ?? false;

    final action = isDone
        ? (isAuto
              ? '${view.name} completed automatically'
              : 'Undo ${view.name}')
        : isSkipped
        ? 'Undo skip for ${view.name}'
        : 'Mark ${view.name} done';

    final streak = view.streak;
    final details = <Widget>[
      if (streak.current > 0) StreakFlame(streak: streak, size: 14),
      if (view.schedule.isWeekly)
        Text(
          '${view.weekDone}/${view.schedule.weeklyTarget} this week',
          style: hud.mono(size: 11),
        ),
      if (isAuto)
        const TagPill('auto', color: AppColors.info, icon: Icons.bolt),
      if (isSkipped) const TagPill('skipped'),
      if (view.upNext)
        const TagPill('Up next', color: AppColors.habit, icon: Icons.east),
      if (!view.upNext && mark == null && view.dependsOnName != null)
        TagPill('after ${view.dependsOnName}'),
      if (muted && !view.schedule.isWeekly)
        Text(view.schedule.describe(), style: hud.mono(size: 11)),
    ];

    return Opacity(
      opacity: muted ? 0.62 : 1,
      child: HabitMilestoneCelebration(
        view: view,
        today: today,
        child: AppCard(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.xs,
            0,
            AppSpacing.xs,
          ),
          accent: isDone && !isAuto ? AppColors.habit : null,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => HabitDetailScreen(habitId: view.id),
            ),
          ),
          child: Row(
            children: [
              Tooltip(
                message: action,
                child: Semantics(
                  button: true,
                  toggled: isDone,
                  label: action,
                  hint: mark == null ? 'Long press to skip today' : null,
                  excludeSemantics: true,
                  onTap: () => HabitActions.toggle(context, ref, view),
                  child: PressableScale(
                    key: Key('habit-check-${view.id}'),
                    haptic: PressHaptic.none,
                    pressedScale: 0.86,
                    onTap: () => HabitActions.toggle(context, ref, view),
                    onLongPress: mark == null
                        ? () => HabitActions.setToday(
                            context,
                            ref,
                            view,
                            HabitStatus.skipped,
                          )
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Hero(
                        tag: 'habit-node-${view.id}',
                        child: HabitCheckNode(
                          state: nodeStateOf(mark),
                          size: 46,
                        ),
                      ),
                    ),
                  ),
                ),
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
                          color: isSkipped ? hud.textMuted : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          HabitWeekStrip(view: view, today: today),
                          ...details,
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More for ${view.name}',
                icon: Icon(Icons.more_vert, color: hud.textMuted),
                onOpened: Haptics.light,
                onSelected: (v) async {
                  switch (v) {
                    case 'done':
                      await HabitActions.setToday(
                        context,
                        ref,
                        view,
                        HabitStatus.done,
                      );
                    case 'skip':
                      await HabitActions.setToday(
                        context,
                        ref,
                        view,
                        HabitStatus.skipped,
                      );
                    case 'undo':
                      await HabitActions.setToday(context, ref, view, null);
                    case 'edit':
                      if (context.mounted) {
                        await openHabitEditor(context, habit: view.habit);
                      }
                  }
                },
                itemBuilder: (_) => [
                  if (!isDone || isAuto)
                    const PopupMenuItem(
                      value: 'done',
                      child: Text('Mark done'),
                    ),
                  if (!isSkipped)
                    const PopupMenuItem(
                      value: 'skip',
                      child: Text('Skip today'),
                    ),
                  if (mark != null && !isAuto)
                    const PopupMenuItem(value: 'undo', child: Text('Undo')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit habit')),
                ],
              ),
            ],
          ),
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
          HudButton(
            label: 'Add habit',
            compact: true,
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
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
    Haptics.success();
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
    final hud = context.hud;
    return AppCard(
      accent: hud.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GlowIcon(Icons.auto_awesome_outlined, size: 16),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'SUGGESTED BY YOUR AI COACH',
                  style: hud.label(size: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(suggestion.content, style: t.bodyLarge),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            alignment: WrapAlignment.end,
            children: [
              HudButton.ghost(
                label: 'Dismiss',
                compact: true,
                onPressed: () => ref
                    .read(habitRepositoryProvider)
                    .respondToSuggestion(suggestion.id, 'dismissed'),
              ),
              HudButton.secondary(
                label: 'Edit',
                compact: true,
                onPressed: () => _edit(context, ref),
              ),
              HudButton(
                label: 'Accept',
                compact: true,
                onPressed: () => _accept(context, ref),
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
