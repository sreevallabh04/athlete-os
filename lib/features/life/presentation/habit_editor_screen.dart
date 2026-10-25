import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import '../domain/auto_rules.dart';
import '../domain/habit_models.dart';
import 'widgets/life_widgets.dart';

/// Create or edit a habit. Pops with the saved habit id.
class HabitEditorScreen extends ConsumerStatefulWidget {
  const HabitEditorScreen({
    super.key,
    this.habit,
    this.initialName,
    this.initialNotes,
  });

  final Habit? habit;
  final String? initialName;
  final String? initialNotes;

  @override
  ConsumerState<HabitEditorScreen> createState() => _HabitEditorScreenState();
}

class _HabitEditorScreenState extends ConsumerState<HabitEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late HabitCategory _category;
  late HabitScheduleType _type;
  late int _daysMask;
  late int _target;
  late List<int> _times;
  String? _dependsOn;
  AutoRule? _autoRule;
  bool _archived = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.habit != null;

  @override
  void initState() {
    super.initState();
    final h = widget.habit;
    final input = h == null ? null : HabitInput.fromHabit(h);
    _name = TextEditingController(
      text: input?.name ?? widget.initialName ?? '',
    );
    _notes = TextEditingController(
      text: input?.notes ?? widget.initialNotes ?? '',
    );
    _category = input?.category ?? HabitCategory.other;
    _type = input?.schedule.type ?? HabitScheduleType.daily;
    _daysMask = input?.schedule.daysMask ?? allDaysMask;
    if (_type == HabitScheduleType.custom && _daysMask & allDaysMask == 0) {
      _daysMask = allDaysMask;
    }
    _target = input?.schedule.weeklyTarget ?? 3;
    _times = [...?input?.reminderTimes];
    _dependsOn = input?.dependsOnHabitId;
    _autoRule = input?.autoRule;
    _archived = input?.archived ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  HabitSchedule get _schedule => switch (_type) {
    HabitScheduleType.daily => const HabitSchedule.daily(),
    HabitScheduleType.weekly => HabitSchedule.weekly(_target),
    HabitScheduleType.custom => HabitSchedule.custom(_daysMask),
  };

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the habit a name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = HabitInput(
      name: name,
      category: _category,
      schedule: _schedule,
      reminderTimes: _times,
      notes: _notes.text,
      dependsOnHabitId: _dependsOn,
      autoRule: _autoRule,
      archived: _archived,
    );
    final repo = ref.read(habitRepositoryProvider);
    try {
      final String id;
      if (_isEdit) {
        id = widget.habit!.id;
        await repo.update(id, input);
      } else {
        id = await repo.create(input);
      }
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = 'Couldn\'t save the habit. Please try again.';
      });
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete habit?'),
        content: const Text(
          'Its history will no longer be shown. Archive it instead if you '
          'might come back to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(habitRepositoryProvider).delete(widget.habit!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final others = (ref.watch(allHabitsProvider).value ?? const <Habit>[])
        .where(
          (h) =>
              h.id != widget.habit?.id &&
              // Prevent simple cycles (A after B after A).
              h.dependsOnHabitId != widget.habit?.id,
        )
        .toList();
    if (_dependsOn != null && !others.any((h) => h.id == _dependsOn)) {
      _dependsOn = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit habit' : 'New habit'),
        actions: [
          if (_isEdit)
            IconButton(
              tooltip: 'Delete habit',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.xxxl,
          ),
          children: [
            TextField(
              controller: _name,
              autofocus: !_isEdit && _name.text.isEmpty,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: 'Name', errorText: _error),
            ),
            const SectionHeader('Category'),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final c in HabitCategory.values)
                  ChoiceChip(
                    label: Text(c.label),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            const SectionHeader('Schedule'),
            SegmentedButton<HabitScheduleType>(
              segments: const [
                ButtonSegment(
                  value: HabitScheduleType.daily,
                  label: Text('Daily'),
                ),
                ButtonSegment(
                  value: HabitScheduleType.weekly,
                  label: Text('Per week'),
                ),
                ButtonSegment(
                  value: HabitScheduleType.custom,
                  label: Text('Days'),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_type == HabitScheduleType.weekly)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$_target ${_target == 1 ? 'time' : 'times'} per week',
                      style: t.titleMedium,
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Fewer',
                    onPressed: _target > 1
                        ? () => setState(() => _target--)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  IconButton.filledTonal(
                    tooltip: 'More',
                    onPressed: _target < 7
                        ? () => setState(() => _target++)
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            if (_type == HabitScheduleType.custom)
              WeekdayPicker(
                mask: _daysMask,
                onChanged: (m) => setState(() => _daysMask = m),
              ),
            Text(switch (_type) {
              HabitScheduleType.daily =>
                'Streaks count consecutive days. Skipped days never break '
                    'them.',
              HabitScheduleType.weekly =>
                'Any days of the week count. Measured Monday to Sunday.',
              HabitScheduleType.custom =>
                'Only the selected days are expected.',
            }, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SectionHeader(
              'Reminders',
              subtitle:
                  'Enable "Habits" in notification settings to receive '
                  'them.',
            ),
            TimesEditor(
              times: _times,
              onChanged: (v) => setState(() => _times = v),
              addLabel: 'Add reminder',
            ),
            const SectionHeader(
              'Complete automatically',
              subtitle: 'Optional. Your own done/skip always takes priority.',
            ),
            DropdownButtonFormField<AutoRule?>(
              initialValue: _autoRule,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Rule'),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final r in AutoRule.values)
                  DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: (v) => setState(() => _autoRule = v),
            ),
            if (_autoRule != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  _autoRule!.description,
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            const SectionHeader(
              'After another habit',
              subtitle: 'Suggested as "Up next" once that habit is done.',
            ),
            DropdownButtonFormField<String?>(
              initialValue: _dependsOn,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Do this after'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('No dependency'),
                ),
                for (final h in others)
                  DropdownMenuItem(value: h.id, child: Text(h.name)),
              ],
              onChanged: (v) => setState(() => _dependsOn = v),
            ),
            const SectionHeader('Notes'),
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Why this habit matters, or how to make it easy',
              ),
            ),
            if (_isEdit) ...[
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Archived'),
                subtitle: const Text('Hidden from today; history is kept.'),
                value: _archived,
                onChanged: (v) => setState(() => _archived = v),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_isEdit ? 'Save changes' : 'Create habit'),
            ),
          ],
        ),
      ),
    );
  }
}
