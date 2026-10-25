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
      Haptics.warning();
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
      Haptics.success();
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      Haptics.warning();
      setState(() {
        _saving = false;
        _error = 'Couldn\'t save the habit. Please try again.';
      });
    }
  }

  Future<void> _delete() async {
    final ok = await confirmHud(
      context,
      title: 'Delete habit?',
      message:
          'Its history will no longer be shown. Archive it instead if you '
          'might come back to it.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(habitRepositoryProvider).delete(widget.habit!.id);
    if (mounted) Navigator.of(context).pop();
  }

  static IconData _categoryIcon(HabitCategory c) => switch (c) {
    HabitCategory.health => Icons.favorite_outline,
    HabitCategory.fitness => Icons.fitness_center,
    HabitCategory.nutrition => Icons.restaurant_outlined,
    HabitCategory.mind => Icons.self_improvement,
    HabitCategory.productivity => Icons.bolt_outlined,
    HabitCategory.other => Icons.category_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
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

    return AppPage(
      title: _isEdit ? 'Edit habit' : 'New habit',
      eyebrow: _isEdit ? 'HABIT · CONFIG' : 'HABIT · NEW',
      actions: [
        if (_isEdit)
          IconButton(
            tooltip: 'Delete habit',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
      ],
      children: [
        TextField(
          controller: _name,
          autofocus: !_isEdit && _name.text.isEmpty,
          maxLength: 60,
          style: t.titleLarge,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. 10-minute walk after lunch',
            errorText: _error,
          ),
        ),
        const SectionHeader('Category'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final c in HabitCategory.values)
              LifePill(
                label: c.label,
                icon: _categoryIcon(c),
                selected: _category == c,
                onTap: () => setState(() => _category = c),
              ),
          ],
        ),
        const SectionHeader('Schedule'),
        SegmentedHud<HabitScheduleType>(
          segments: const [
            HudSegment(value: HabitScheduleType.daily, label: 'Daily'),
            HudSegment(value: HabitScheduleType.weekly, label: 'Per week'),
            HudSegment(value: HabitScheduleType.custom, label: 'Days'),
          ],
          value: _type,
          onChanged: (v) => setState(() => _type = v),
        ),
        const SizedBox(height: AppSpacing.md),
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          alignment: Alignment.topCenter,
          child: switch (_type) {
            HabitScheduleType.weekly => GlassPanel(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: HudStepper(
                label: 'Times per week',
                value: _target,
                min: 1,
                max: 7,
                unit: _target == 1 ? 'TIME PER WEEK' : 'TIMES PER WEEK',
                color: AppColors.habit,
                onChanged: (v) => setState(() => _target = v),
              ),
            ),
            HabitScheduleType.custom => WeekdayPicker(
              mask: _daysMask,
              color: AppColors.habit,
              onChanged: (m) => setState(() => _daysMask = m),
            ),
            HabitScheduleType.daily => const SizedBox(width: double.infinity),
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(switch (_type) {
          HabitScheduleType.daily =>
            'Streaks count consecutive days. Skipped days never break them.',
          HabitScheduleType.weekly =>
            'Any days of the week count. Measured Monday to Sunday.',
          HabitScheduleType.custom => 'Only the selected days are expected.',
        }, style: t.bodySmall?.copyWith(color: hud.textMuted)),
        const LifeSection(
          'Reminders',
          hint: 'Enable "Habits" in notification settings to receive them.',
        ),
        TimesEditor(
          times: _times,
          onChanged: (v) => setState(() => _times = v),
          addLabel: 'Add reminder',
        ),
        const LifeSection(
          'Complete automatically',
          hint: 'Optional. Your own done/skip always takes priority.',
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            LifePill(
              label: 'None',
              selected: _autoRule == null,
              onTap: () => setState(() => _autoRule = null),
            ),
            for (final r in AutoRule.values)
              LifePill(
                label: r.label,
                icon: Icons.bolt,

                selected: _autoRule == r,
                onTap: () => setState(() => _autoRule = r),
              ),
          ],
        ),
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          child: _autoRule == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    _autoRule!.description,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ),
        ),
        if (others.isNotEmpty) ...[
          const LifeSection(
            'After another habit',
            hint: 'Suggested as "Up next" once that habit is done.',
          ),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              LifePill(
                label: 'No dependency',
                selected: _dependsOn == null,
                onTap: () => setState(() => _dependsOn = null),
              ),
              for (final h in others)
                LifePill(
                  label: h.name,
                  icon: Icons.east,

                  selected: _dependsOn == h.id,
                  onTap: () => setState(() => _dependsOn = h.id),
                ),
            ],
          ),
        ],
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
          AppCard(
            child: HudRow(
              leading: GlowIcon(
                Icons.archive_outlined,
                color: hud.textMuted,
                glow: 0,
              ),
              title: 'Archived',
              subtitle: 'Hidden from today; history is kept.',
              trailing: HudToggle(
                value: _archived,
                semanticLabel: 'Archived',
                onChanged: (v) => setState(() => _archived = v),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        HudButton(
          label: _isEdit ? 'Save changes' : 'Create habit',
          icon: Icons.check_rounded,
          expand: true,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
