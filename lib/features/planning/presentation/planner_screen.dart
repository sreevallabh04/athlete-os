import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/domain/free_slots.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../onboarding/presentation/routine_screen.dart';
import '../application/planning_providers.dart';
import '../data/planning_repository.dart';
import '../domain/planner_rules.dart';
import '../domain/task_rules.dart';
import 'widgets/review_sheets.dart';
import 'widgets/ui_helpers.dart';

/// Deep link the AI coach will handle once AI planning ships. The button is
/// intentionally disabled until then.
const coachPlanDayLink = '${AppPaths.coach}?prompt=Plan%20my%20day';
const coachPlanningEnabled = false;

class PlannerScreen extends ConsumerStatefulWidget {
  const PlannerScreen({super.key});

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends ConsumerState<PlannerScreen> {
  late String _date = LocalDates.key(ref.read(clockProvider).now());

  String get _today => LocalDates.key(ref.read(clockProvider).now());

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksForDateProvider(_date));
    return AppPage(
      title: 'Plan your day',
      eyebrow: _date == _today
          ? 'TODAY · ${formatDateKey(_date, pattern: 'EEE d MMM').toUpperCase()}'
          : formatDateKey(_date, pattern: 'EEE d MMM yyyy').toUpperCase(),
      onRefresh: () async {
        ref.invalidate(calendarDayProvider(_date));
        ref.invalidate(tasksForDateProvider(_date));
      },
      floatingActionButton: HudButton(
        label: 'Add priority',
        icon: Icons.add_task,
        onPressed: () => _editTask(context),
      ),
      children: [
        _DateStrip(
          selected: _date,
          today: _today,
          onSelect: (d) => setState(() => _date = d),
        ),
        if (_date == _today) _CarryoverBanner(today: _date),
        const SectionHeader('Priorities', subtitle: 'Drag to reorder'),
        tasks.when(
          loading: () => const LoadingState(),
          error: (e, _) => const ErrorState(message: 'Could not load tasks.'),
          data: (list) => _TaskList(
            date: _date,
            tasks: list,
            onEdit: (t) => _editTask(context, t),
          ),
        ),
        const SectionHeader('Timeline'),
        _Timeline(
          date: _date,
          isToday: _date == _today,
          tasks: tasks.value ?? const [],
        ),
        if (_date == _today) const RoutineSection(),
        const SectionHeader('Reviews'),
        Row(
          children: [
            Expanded(
              child: _ReviewTile(
                icon: Icons.nightlight_outlined,
                title: 'End-of-day review',
                sub: 'Wins, misses, tomorrow',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => EndOfDayReviewSheet(date: _date),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _ReviewTile(
                icon: Icons.calendar_view_week,
                title: 'Weekly review',
                sub: 'Patterns and focus',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => WeeklyReviewSheet(anyDateInWeek: _date),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: coachPlanningEnabled
                    ? () => context.push(coachPlanDayLink)
                    : null,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Ask coach to plan my day'),
              ),
              const SizedBox(height: AppSpacing.xs),
              const Hint(
                'Coming soon: AI-generated schedules. Suggestions above are '
                'deterministic and only become tasks when you add them.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _editTask(BuildContext context, [TaskItem? existing]) async {
    final r = await showDialog<(String, int, String?)>(
      context: context,
      builder: (_) => _TaskDialog(existing: existing),
    );
    if (r == null) return;
    final repo = ref.read(planningRepositoryProvider);
    final (title, priority, project) = r;
    if (existing == null) {
      await repo.addTask(
        title: title,
        date: _date,
        priority: priority,
        project: project,
      );
    } else {
      await repo.updateTask(
        existing.id,
        title: title,
        priority: priority,
        project: project,
      );
    }
  }
}

class _DateStrip extends StatelessWidget {
  const _DateStrip({
    required this.selected,
    required this.today,
    required this.onSelect,
  });
  final String selected;
  final String today;
  final ValueChanged<String> onSelect;

  void _pick(String d) {
    Haptics.selection();
    onSelect(d);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final monday = LocalDates.weekStart(selected);
    final days = [for (var i = 0; i < 7; i++) LocalDates.addDays(monday, i)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous week',
              onPressed: () => _pick(LocalDates.addDays(selected, -7)),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${formatDateKey(monday, pattern: 'd MMM')} – '
                        '${formatDateKey(days.last, pattern: 'd MMM')}'
                    .toUpperCase(),
                textAlign: TextAlign.center,
                style: hud.mono(size: 11),
              ),
            ),
            IconButton(
              tooltip: 'Pick a date',
              onPressed: () async {
                final d = await pickDateKey(context, initial: selected);
                if (d != null) _pick(d);
              },
              icon: const Icon(Icons.calendar_month_outlined),
            ),
            IconButton(
              tooltip: 'Next week',
              onPressed: () => _pick(LocalDates.addDays(selected, 7)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            for (final d in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Semantics(
                    selected: d == selected,
                    button: true,
                    label: formatDateKey(d),
                    excludeSemantics: true,
                    child: PressableScale(
                      onTap: d == selected ? null : () => _pick(d),
                      haptic: PressHaptic.none,
                      pressedScale: 0.92,
                      child: AnimatedContainer(
                        duration: AppMotion.medium,
                        curve: AppMotion.emphasizedDecelerate,
                        constraints: const BoxConstraints(minHeight: 60),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          gradient: d == selected
                              ? LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    hud.accent.withValues(alpha: 0.32),
                                    hud.accent.withValues(alpha: 0.10),
                                  ],
                                )
                              : null,
                          color: d == selected ? null : hud.glassFill,
                          border: Border.all(
                            color: d == selected
                                ? hud.accent.withValues(alpha: 0.8)
                                : d == today
                                ? hud.accent.withValues(alpha: 0.45)
                                : hud.hairline.withValues(alpha: 0.12),
                          ),
                          boxShadow: d == selected
                              ? AppGlows.soft(
                                  hud.accent,
                                  strength: hud.glowStrength,
                                )
                              : null,
                        ),
                        child: Column(
                          children: [
                            Text(
                              DateFormat('E')
                                  .format(LocalDates.parse(d))
                                  .toUpperCase(),
                              style: hud.label(
                                size: 9.5,
                                color: d == selected
                                    ? hud.accentInk
                                    : hud.textMuted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${LocalDates.parse(d).day}',
                              style: t.titleMedium?.copyWith(
                                fontFamily: AppFonts.display,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (d == today)
                              Container(
                                width: 4,
                                height: 4,
                                margin: const EdgeInsets.only(top: 2),
                                decoration: BoxDecoration(
                                  color: hud.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Offers yesterday's unfinished tasks; nothing moves without a tap.
class _CarryoverBanner extends ConsumerWidget {
  const _CarryoverBanner({required this.today});
  final String today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final yesterday = LocalDates.addDays(today, -1);
    final tasks = ref.watch(tasksForDateProvider(yesterday)).value ?? const [];
    final dismissed = ref.watch(_dismissedProvider(today)).value;
    final candidates = carryoverCandidates(tasks, previousDate: yesterday);
    if (candidates.isEmpty || dismissed == true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: NoticeBanner(
        icon: Icons.redo,
        color: AppColors.warning,
        message:
            '${candidates.length} unfinished '
            '${candidates.length == 1 ? 'priority' : 'priorities'} from '
            'yesterday.',
        actionLabel: 'Review',
        onAction: () async {
          final chosen = await showDialog<Set<String>?>(
            context: context,
            builder: (_) => _CarryoverDialog(candidates: candidates),
          );
          if (chosen == null) return;
          if (chosen.isEmpty) {
            await ref
                .read(settingsRepositoryProvider)
                .set(PlanningKeys.carryoverDismissed(today), true);
            return;
          }
          final n = await ref
              .read(planningRepositoryProvider)
              .carryOver(chosen, today);
          if (context.mounted) showSnack(context, 'Carried over $n to today');
        },
      ),
    );
  }
}

final _dismissedProvider = StreamProvider.autoDispose.family<bool?, String>(
  (ref, date) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(PlanningKeys.carryoverDismissed(date)),
);

class _CarryoverDialog extends StatefulWidget {
  const _CarryoverDialog({required this.candidates});
  final List<TaskItem> candidates;

  @override
  State<_CarryoverDialog> createState() => _CarryoverDialogState();
}

class _CarryoverDialogState extends State<_CarryoverDialog> {
  late final Set<String> _selected = widget.candidates.map((t) => t.id).toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Carry over to today?'),
      content: SizedBox(
        width: 400,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final t in widget.candidates)
              CheckboxListTile(
                value: _selected.contains(t.id),
                title: Text(t.title),
                subtitle: Text(
                  'P${t.priority}${t.project != null ? ' · ${t.project}' : ''}',
                ),
                onChanged: (v) => setState(
                  () =>
                      v == true ? _selected.add(t.id) : _selected.remove(t.id),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, <String>{}),
          child: const Text('Not today'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected),
          child: Text('Carry over ${_selected.length}'),
        ),
      ],
    );
  }
}

class _TaskList extends ConsumerWidget {
  const _TaskList({
    required this.date,
    required this.tasks,
    required this.onEdit,
  });
  final String date;
  final List<TaskItem> tasks;
  final ValueChanged<TaskItem> onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    if (tasks.isEmpty) {
      return AppCard(
        child: Row(
          children: [
            const GlowIcon(Icons.flag_outlined, framed: true, size: 18),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No priorities yet', style: t.titleSmall),
                  Text(
                    'Add up to three things that would make today a win.',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final repo = ref.read(planningRepositoryProvider);
    final done = tasks.where((t) => t.done).length;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: MetricBar(
              label: 'Done',
              value: done.toDouble(),
              target: tasks.length.toDouble(),
              color: hud.accent,
              segments: tasks.length.clamp(1, 24),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            proxyDecorator: (child, _, _) =>
                Material(type: MaterialType.transparency, child: child),
            onReorderItem: (oldIndex, newIndex) {
              Haptics.selection();
              final ids = tasks.map((t) => t.id).toList();
              final id = ids.removeAt(oldIndex);
              ids.insert(newIndex, id);
              repo.setTaskOrder(date, ids);
            },
            children: [
              for (var i = 0; i < tasks.length; i++)
                _PlannerTaskRow(
                  key: ValueKey(tasks[i].id),
                  task: tasks[i],
                  index: i,
                  onEdit: () => onEdit(tasks[i]),
                  onToggle: () async {
                    final v = !tasks[i].done;
                    await repo.setTaskDone(tasks[i].id, v);
                    v ? Haptics.success() : Haptics.selection();
                  },
                  onDelete: () async {
                    Haptics.medium();
                    await repo.deleteTask(tasks[i].id);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlannerTaskRow extends StatelessWidget {
  const _PlannerTaskRow({
    super.key,
    required this.task,
    required this.index,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final TaskItem task;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final pColor = switch (task.priority) {
      1 => AppColors.red,
      2 => AppColors.warning,
      _ => hud.accent,
    };
    final sub = [
      ?task.project,
      if (task.carriedFromDate != null)
        'carried from ${formatDateKey(task.carriedFromDate!, pattern: 'd MMM')}',
    ].join(' · ');
    return PressableScale(
      onTap: onEdit,
      pressedScale: 0.98,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Semantics(
              checked: task.done,
              label: 'Done: ${task.title}',
              child: IconButton(
                tooltip: task.done ? 'Mark not done' : 'Mark done',
                onPressed: onToggle,
                icon: AnimatedContainer(
                  duration: AppMotion.medium,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: task.done ? hud.accent : Colors.transparent,
                    border: Border.all(
                      color: task.done
                          ? hud.accent
                          : hud.textMuted.withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                  ),
                  child: task.done
                      ? const Icon(
                          Icons.check,
                          size: 14,
                          color: Color(0xFF02141C),
                        )
                      : null,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: t.bodyLarge?.copyWith(
                      decoration: task.done ? TextDecoration.lineThrough : null,
                      color: task.done ? hud.textMuted : null,
                    ),
                  ),
                  Text(
                    sub.isEmpty
                        ? 'P${task.priority}'
                        : 'P${task.priority} · $sub',
                    style: hud.mono(size: 10, color: pColor),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: hud.textMuted),
              onPressed: onDelete,
            ),
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.drag_indicator, color: hud.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskDialog extends StatefulWidget {
  const _TaskDialog({this.existing});
  final TaskItem? existing;

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _project = TextEditingController(text: widget.existing?.project);
  late int _priority = widget.existing?.priority ?? 2;

  @override
  void dispose() {
    _title.dispose();
    _project.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add priority' : 'Edit priority'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Task'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('P1')),
              ButtonSegment(value: 2, label: Text('P2')),
              ButtonSegment(value: 3, label: Text('P3')),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _project,
            decoration: const InputDecoration(
              labelText: 'Project / tag (optional)',
              hintText: 'e.g. Workout, Work, Prep',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (
                  _title.text.trim(),
                  _priority,
                  _project.text.trim().isEmpty ? null : _project.text.trim(),
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Timeline extends ConsumerWidget {
  const _Timeline({
    required this.date,
    required this.isToday,
    required this.tasks,
  });
  final String date;
  final bool isToday;
  final List<TaskItem> tasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final cal = ref.watch(calendarDayProvider(date));
    final now = ref.watch(clockProvider).now();
    if (profile == null || cal.isLoading && !cal.hasValue) {
      return const LoadingState();
    }
    final result = cal.value ?? const CalendarReadResult.notConnected();
    final day = LocalDates.parse(date);
    var window = dayWindow(day, profile.wakeMinutes, profile.sleepMinutes);
    if (isToday) window = clipToNow(window, now);
    final events = [...result.events]
      ..sort((a, b) => a.start.compareTo(b.start));
    final busy = [
      for (final e in events)
        if (e.isBusy && !e.allDay) TimeInterval(e.start, e.end),
    ];
    final free = findFreeSlots(
      window: window,
      busy: busy,
      minDuration: const Duration(minutes: 30),
      buffer: const Duration(minutes: 10),
    );
    final hasWorkoutTask = tasks.any(
      (t) => (t.project ?? '').toLowerCase() == 'workout',
    );
    final suggestions = suggestBlocks(free, includeWorkout: !hasWorkoutTask);
    final t = Theme.of(context).textTheme;

    final items = <(DateTime, Widget)>[
      for (final e in events.where((e) => !e.allDay))
        (e.start, _EventRow(title: e.title, start: e.start, end: e.end)),
      for (final s in free) (s.start, _FreeRow(slot: s)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!result.connected)
          NoticeBanner(
            icon: Icons.link_off,
            message:
                'Google Calendar is not connected, so events are not shown and '
                'free time ignores them.',
            actionLabel: 'Connect',
            onAction: () => context.push(AppPaths.integrations),
          )
        else if (result.error != null)
          const NoticeBanner(
            icon: Icons.cloud_off,
            color: AppColors.warning,
            message:
                'Calendar could not be loaded; free time may conflict with '
                'events.',
          ),
        for (final e in events.where((e) => e.allDay))
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text('All day · ${e.title}', style: t.labelLarge),
          ),
        const SizedBox(height: AppSpacing.md),
        DayRibbon(
          window: dayWindow(day, profile.wakeMinutes, profile.sleepMinutes),
          busy: busy,
          free: free,
          now: isToday ? now : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        Hint(
          'Day window ${Fmt.time(window.start)} – ${Fmt.time(window.end)} '
          '(wake/sleep from your profile) · free slots ≥ 30 min.',
        ),
        const SizedBox(height: AppSpacing.sm),
        if (items.isEmpty)
          const Hint('No free time of 30 minutes or more left in this window.')
        else
          for (final (_, w) in items) w,
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text('Suggested blocks', style: t.titleSmall),
          const Hint(
            'Deterministic proposals in your free time — nothing is added until you choose.',
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final s in suggestions)
            _SuggestionCard(
              suggestion: s,
              date: date,
              calendarConnected: result.connected,
            ),
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.title,
    required this.start,
    required this.end,
  });
  final String title;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(Fmt.time(start), style: t.labelMedium),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: const Border(
                  left: BorderSide(color: AppColors.info, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.bodyMedium),
                  Text(
                    '${Fmt.time(start)} – ${Fmt.time(end)} · Google Calendar',
                    style: t.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FreeRow extends StatelessWidget {
  const _FreeRow({required this.slot});
  final TimeInterval slot;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final m = slot.duration.inMinutes;
    final dur = m >= 60 ? '${m ~/ 60} h ${m % 60} m' : '$m min';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(Fmt.time(slot.start), style: t.labelMedium),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: AppColors.success.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                'Free · $dur (until ${Fmt.time(slot.end)})',
                style: t.bodySmall?.copyWith(color: AppColors.success),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends ConsumerWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.date,
    required this.calendarConnected,
  });
  final BlockSuggestion suggestion;
  final String date;
  final bool calendarConnected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = suggestion;
    final t = Theme.of(context).textTheme;
    final (icon, color) = switch (s.kind) {
      BlockKind.workout => (Icons.fitness_center, AppColors.strength),
      BlockKind.focus => (Icons.center_focus_strong, AppColors.brand),
      BlockKind.mealPrep => (Icons.soup_kitchen_outlined, AppColors.calories),
    };
    final range = '${Fmt.time(s.slot.start)} – ${Fmt.time(s.slot.end)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        accent: color,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('${s.title} · $range', style: t.titleSmall),
                ),
              ],
            ),
            Hint(s.reason),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                HudButton.secondary(
                  label: 'Add as task',
                  icon: Icons.add,
                  compact: true,
                  onPressed: () async {
                    await ref
                        .read(planningRepositoryProvider)
                        .addTask(
                          title: '${s.title} ($range)',
                          date: date,
                          priority: s.kind == BlockKind.workout ? 1 : 2,
                          project: s.project,
                        );
                    Haptics.success();
                    if (context.mounted) {
                      showSnack(context, 'Added to priorities');
                    }
                  },
                ),
                Tooltip(
                  message: calendarConnected
                      ? 'Writing to Google Calendar is not available yet'
                      : 'Connect Google Calendar to add events',
                  child: const HudButton.ghost(
                    label: 'Add to calendar',
                    compact: true,
                    onPressed: null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlowIcon(icon, size: 18, framed: true),
          const SizedBox(height: AppSpacing.sm),
          Text(title, style: t.titleSmall),
          Text(sub, style: t.bodySmall?.copyWith(color: context.hud.textMuted)),
        ],
      ),
    );
  }
}

/// The day as one horizontal ribbon: busy calendar time, free slots and a
/// "now" marker across the wake → sleep window.
class DayRibbon extends StatelessWidget {
  const DayRibbon({
    super.key,
    required this.window,
    required this.busy,
    required this.free,
    this.now,
  });

  final TimeInterval window;
  final List<TimeInterval> busy;
  final List<TimeInterval> free;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final totalMin = window.end.difference(window.start).inMinutes;
    if (totalMin <= 0) return const SizedBox.shrink();
    double x(DateTime t) =>
        (t.difference(window.start).inMinutes / totalMin).clamp(0.0, 1.0);
    final freeMin = free.fold<int>(0, (s, f) => s + f.duration.inMinutes);
    final hours = <DateTime>[
      for (
        var h = DateTime(
          window.start.year,
          window.start.month,
          window.start.day,
          window.start.hour + 1,
        );
        h.isBefore(window.end);
        h = h.add(const Duration(hours: 3))
      )
        h,
    ];
    return Semantics(
      label:
          'Day ribbon: ${freeMin ~/ 60} hours ${freeMin % 60} minutes free '
          'between ${Fmt.time(window.start)} and ${Fmt.time(window.end)}',
      excludeSemantics: true,
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('FREE TIME', style: hud.label(size: 10.5)),
                const Spacer(),
                Text(
                  '${freeMin ~/ 60} H ${freeMin % 60} M',
                  style: hud.mono(size: 10.5, color: AppColors.success),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth;
                Widget seg(TimeInterval i, Color fill, Color border) =>
                    Positioned(
                      left: w * x(i.start),
                      width: (w * (x(i.end) - x(i.start))).clamp(2.0, w),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: border),
                        ),
                      ),
                    );
                return SizedBox(
                  height: 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: hud.text.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      for (final f in free)
                        seg(
                          f,
                          AppColors.success.withValues(alpha: 0.18),
                          AppColors.success.withValues(alpha: 0.55),
                        ),
                      for (final b in busy)
                        seg(
                          b,
                          hud.accent.withValues(alpha: 0.35),
                          hud.accent.withValues(alpha: 0.8),
                        ),
                      if (now != null &&
                          now!.isAfter(window.start) &&
                          now!.isBefore(window.end))
                        Positioned(
                          left: w * x(now!) - 1,
                          top: -4,
                          bottom: -4,
                          child: Container(
                            width: 2,
                            decoration: BoxDecoration(
                              color: hud.text,
                              boxShadow: [
                                BoxShadow(
                                  color: hud.accent.withValues(alpha: 0.9),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (context, box) => SizedBox(
                height: 14,
                child: Stack(
                  children: [
                    for (final h in hours)
                      Positioned(
                        left: (box.maxWidth * x(h) - 6).clamp(
                          0.0,
                          box.maxWidth - 30,
                        ),
                        child: Text(
                          DateFormat('HH').format(h),
                          style: hud.mono(size: 9.5),
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
