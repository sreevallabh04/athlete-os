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
      onRefresh: () async {
        ref.invalidate(calendarDayProvider(_date));
        ref.invalidate(tasksForDateProvider(_date));
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editTask(context),
        icon: const Icon(Icons.add_task),
        label: const Text('Add priority'),
      ),
      children: [
        _DateStrip(
          selected: _date,
          today: _today,
          onSelect: (d) => setState(() => _date = d),
        ),
        if (_date == _today) _CarryoverBanner(today: _date),
        const SectionHeader(
          'Priorities',
          subtitle: 'Drag to reorder · P1 is most important',
        ),
        tasks.when(
          loading: () => const LoadingState(),
          error: (e, _) => const ErrorState(message: 'Could not load tasks.'),
          data: (list) => _TaskList(
            date: _date,
            tasks: list,
            onEdit: (t) => _editTask(context, t),
          ),
        ),
        const SectionHeader(
          'Timeline',
          subtitle: 'Calendar, free time and suggested blocks',
        ),
        _Timeline(
          date: _date,
          isToday: _date == _today,
          tasks: tasks.value ?? const [],
        ),
        const SectionHeader('Reviews'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                useSafeArea: true,
                builder: (_) => EndOfDayReviewSheet(date: _date),
              ),
              icon: const Icon(Icons.nightlight_outlined),
              label: const Text('End-of-day review'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                useSafeArea: true,
                builder: (_) => WeeklyReviewSheet(anyDateInWeek: _date),
              ),
              icon: const Icon(Icons.calendar_view_week),
              label: const Text('Weekly review'),
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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final monday = LocalDates.weekStart(selected);
    final days = [for (var i = 0; i < 7; i++) LocalDates.addDays(monday, i)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous week',
              onPressed: () => onSelect(LocalDates.addDays(selected, -7)),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                selected == today
                    ? 'Today · ${formatDateKey(selected, pattern: 'EEE d MMM')}'
                    : formatDateKey(selected),
                textAlign: TextAlign.center,
                style: t.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Pick a date',
              onPressed: () async {
                final d = await pickDateKey(context, initial: selected);
                if (d != null) onSelect(d);
              },
              icon: const Icon(Icons.calendar_month_outlined),
            ),
            IconButton(
              tooltip: 'Next week',
              onPressed: () => onSelect(LocalDates.addDays(selected, 7)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
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
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      onTap: () => onSelect(d),
                      child: AnimatedContainer(
                        duration: AppDurations.fast,
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          gradient: d == selected ? AppGradients.brand : null,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          border: d == today && d != selected
                              ? Border.all(color: AppColors.brand)
                              : null,
                        ),
                        child: Column(
                          children: [
                            Text(
                              DateFormat('E')
                                  .format(LocalDates.parse(d))
                                  .substring(0, 1),
                              style: t.labelSmall?.copyWith(
                                color: d == selected
                                    ? Colors.white
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              '${LocalDates.parse(d).day}',
                              style: t.titleMedium?.copyWith(
                                color: d == selected ? Colors.white : null,
                                fontWeight: FontWeight.w700,
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
    if (tasks.isEmpty) {
      return const AppCard(
        child: EmptyState(
          compact: true,
          icon: Icons.flag_outlined,
          title: 'No priorities yet',
          message: 'Add up to three things that would make today a win.',
        ),
      );
    }
    final repo = ref.read(planningRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: (oldIndex, newIndex) {
          final ids = tasks.map((t) => t.id).toList();
          final id = ids.removeAt(oldIndex);
          ids.insert(newIndex, id);
          repo.setTaskOrder(date, ids);
        },
        children: [
          for (var i = 0; i < tasks.length; i++)
            ListTile(
              key: ValueKey(tasks[i].id),
              leading: Checkbox(
                value: tasks[i].done,
                onChanged: (v) => repo.setTaskDone(tasks[i].id, v ?? false),
              ),
              title: Text(
                tasks[i].title,
                style: TextStyle(
                  decoration: tasks[i].done ? TextDecoration.lineThrough : null,
                  color: tasks[i].done ? scheme.onSurfaceVariant : null,
                ),
              ),
              subtitle: Text(
                [
                  'P${tasks[i].priority}',
                  ?tasks[i].project,
                  if (tasks[i].carriedFromDate != null)
                    'carried from ${formatDateKey(tasks[i].carriedFromDate!, pattern: 'd MMM')}',
                ].join(' · '),
              ),
              onTap: () => onEdit(tasks[i]),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => repo.deleteTask(tasks[i].id),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_indicator),
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
                FilledButton.tonal(
                  onPressed: () async {
                    await ref
                        .read(planningRepositoryProvider)
                        .addTask(
                          title: '${s.title} ($range)',
                          date: date,
                          priority: s.kind == BlockKind.workout ? 1 : 2,
                          project: s.project,
                        );
                    if (context.mounted) {
                      showSnack(context, 'Added to priorities');
                    }
                  },
                  child: const Text('Add as task'),
                ),
                Tooltip(
                  message: calendarConnected
                      ? 'Writing to Google Calendar is not available yet'
                      : 'Connect Google Calendar to add events',
                  child: const OutlinedButton(
                    onPressed: null,
                    child: Text('Add to calendar'),
                  ),
                ),
                if (!calendarConnected)
                  Text('Connect Google Calendar', style: t.labelSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
