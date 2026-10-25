import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/planning_providers.dart';
import '../../data/planning_repository.dart';
import '../../domain/countdown.dart';
import '../../domain/planner_rules.dart';
import 'ui_helpers.dart';

/// Vertical prep timeline: prep start → dated milestones → today → show day.
class PrepTimeline extends StatelessWidget {
  const PrepTimeline({super.key, required this.view, required this.items});
  final CompetitionView view;
  final List<CompetitionMilestone> items;

  @override
  Widget build(BuildContext context) {
    final c = view.countdown;
    final today = c.todayInEventTz.key;
    final entries =
        <(String date, String title, IconData icon, Color color, bool done)>[
          if (c.prepStart != null)
            (
              c.prepStart!.key,
              'Prep started',
              Icons.flag_outlined,
              AppColors.info,
              true,
            ),
          for (final m in items.where((m) => m.dueDate != null))
            (
              m.dueDate!,
              m.title,
              m.kind == 'checklist' ? Icons.checklist : Icons.outlined_flag,
              m.done ? AppColors.success : AppColors.gold,
              m.done,
            ),
          (today, 'Today', Icons.radio_button_checked, AppColors.brand, false),
          (
            c.eventDate.key,
            view.competition.name,
            Icons.emoji_events,
            AppColors.gold,
            c.phase == CountdownPhase.past,
          ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));

    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(
            icon: Icons.timeline,
            title: 'Prep timeline',
            color: AppColors.gold,
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < entries.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 28,
                    child: Column(
                      children: [
                        Icon(entries[i].$3, size: 18, color: entries[i].$4),
                        if (i < entries.length - 1)
                          Expanded(
                            child: Container(
                              width: 2,
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              color: scheme.outlineVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entries[i].$2,
                            style: t.bodyMedium?.copyWith(
                              fontWeight: entries[i].$2 == 'Today'
                                  ? FontWeight.w700
                                  : null,
                              decoration:
                                  entries[i].$5 &&
                                      entries[i].$3 != Icons.flag_outlined &&
                                      entries[i].$3 != Icons.emoji_events
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          Text(
                            formatDateKey(entries[i].$1, pattern: 'EEE d MMM'),
                            style: t.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
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

/// Milestones and checklist CRUD for a competition.
class MilestonesSection extends ConsumerWidget {
  const MilestonesSection({super.key, required this.view});
  final CompetitionView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = view.competition.id;
    final items = ref.watch(milestonesProvider(id));
    final t = Theme.of(context).textTheme;
    return items.when(
      loading: () => const LoadingState(),
      error: (e, _) => const ErrorState(message: 'Could not load milestones.'),
      data: (list) {
        final milestones = list.where((m) => m.kind != 'checklist').toList();
        final checklist = list.where((m) => m.kind == 'checklist').toList();
        final done = list.where((m) => m.done).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PrepTimeline(view: view, items: list),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CardTitle(
                    icon: Icons.checklist,
                    title: 'Milestones & checklist',
                    color: AppColors.gold,
                    trailing: list.isEmpty
                        ? null
                        : Text(
                            '$done/${list.length} done',
                            style: t.labelMedium,
                          ),
                  ),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Hint(
                        'No milestones yet. Add your own, or pick from the '
                        'suggested prep checklist.',
                      ),
                    ),
                  if (milestones.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text('Milestones', style: t.labelLarge),
                    for (final m in milestones) _MilestoneTile(m: m),
                  ],
                  if (checklist.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text('Prep checklist', style: t.labelLarge),
                    for (final m in checklist) _MilestoneTile(m: m),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      HudButton.secondary(
                        compact: true,
                        onPressed: () => _editItem(context, ref, id),
                        icon: Icons.add,
                        label: 'Add item',
                      ),
                      HudButton.ghost(
                        compact: true,
                        onPressed: () => _addSuggested(context, ref, id, list),
                        icon: Icons.playlist_add,
                        label: 'Add suggested checklist',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _addSuggested(
    BuildContext context,
    WidgetRef ref,
    String competitionId,
    List<CompetitionMilestone> existing,
  ) async {
    final have = existing.map((m) => m.title.toLowerCase()).toSet();
    final options = suggestedPrepChecklist
        .where((s) => !have.contains(s.toLowerCase()))
        .toList();
    if (options.isEmpty) {
      showSnack(context, 'All suggested items are already on your list.');
      return;
    }
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => _SuggestionPicker(options: options),
    );
    if (chosen == null || chosen.isEmpty) return;
    final repo = ref.read(planningRepositoryProvider);
    for (final c in chosen) {
      await repo.addMilestone(
        competitionId: competitionId,
        title: c,
        kind: 'checklist',
      );
    }
  }

  static Future<void> _editItem(
    BuildContext context,
    WidgetRef ref,
    String competitionId, [
    CompetitionMilestone? existing,
  ]) async {
    final result = await showDialog<(String, String, String?)>(
      context: context,
      builder: (_) => _MilestoneDialog(existing: existing),
    );
    if (result == null) return;
    final repo = ref.read(planningRepositoryProvider);
    final (title, kind, due) = result;
    if (existing == null) {
      await repo.addMilestone(
        competitionId: competitionId,
        title: title,
        kind: kind,
        dueDate: due,
      );
    } else {
      await repo.updateMilestone(
        existing.id,
        title: title,
        kind: kind,
        dueDate: due,
      );
    }
  }
}

class _MilestoneTile extends ConsumerWidget {
  const _MilestoneTile({required this.m});
  final CompetitionMilestone m;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final repo = ref.read(planningRepositoryProvider);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: m.done,
      onChanged: (v) => repo.setMilestoneDone(m.id, v ?? false),
      title: Text(
        m.title,
        style: TextStyle(
          decoration: m.done ? TextDecoration.lineThrough : null,
          color: m.done ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: m.dueDate == null
          ? null
          : Text('Due ${formatDateKey(m.dueDate!)}'),
      secondary: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (v) async {
          if (v == 'edit') {
            await MilestonesSection._editItem(context, ref, m.competitionId, m);
          } else if (v == 'delete') {
            await repo.deleteMilestone(m.id);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

class _SuggestionPicker extends StatefulWidget {
  const _SuggestionPicker({required this.options});
  final List<String> options;

  @override
  State<_SuggestionPicker> createState() => _SuggestionPickerState();
}

class _SuggestionPickerState extends State<_SuggestionPicker> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Suggested prep checklist'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Hint(
              'Pick the items that fit your prep. Peak-week and any water or '
              'food manipulation should only be planned with a qualified '
              'coach or clinician.',
            ),
            for (final o in widget.options)
              CheckboxListTile(
                value: _selected.contains(o),
                title: Text(o),
                onChanged: (v) => setState(
                  () => v == true ? _selected.add(o) : _selected.remove(o),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  widget.options.where(_selected.contains).toList(),
                ),
          child: Text('Add ${_selected.length}'),
        ),
      ],
    );
  }
}

class _MilestoneDialog extends StatefulWidget {
  const _MilestoneDialog({this.existing});
  final CompetitionMilestone? existing;

  @override
  State<_MilestoneDialog> createState() => _MilestoneDialogState();
}

class _MilestoneDialogState extends State<_MilestoneDialog> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late String _kind = widget.existing?.kind ?? 'milestone';
  late String? _due = widget.existing?.dueDate;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add item' : 'Edit item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'milestone', label: Text('Milestone')),
              ButtonSegment(value: 'checklist', label: Text('Checklist')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  _due == null ? 'No due date' : 'Due ${formatDateKey(_due!)}',
                ),
              ),
              TextButton(
                onPressed: () async {
                  final d = await pickDateKey(context, initial: _due);
                  if (d != null) setState(() => _due = d);
                },
                child: const Text('Pick date'),
              ),
              if (_due != null)
                IconButton(
                  tooltip: 'Clear date',
                  onPressed: () => setState(() => _due = null),
                  icon: const Icon(Icons.clear),
                ),
            ],
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
              : () => Navigator.pop(context, (_title.text.trim(), _kind, _due)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
