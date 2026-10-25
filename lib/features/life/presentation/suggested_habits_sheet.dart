import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../data/habit_repository.dart';
import '../domain/habit_models.dart';
import '../domain/suggested_habits.dart';
import 'widgets/habit_widgets.dart';

Future<void> showSuggestedHabitsSheet(BuildContext context) =>
    showHudBottomSheet<void>(
      context,
      title: 'Suggested habits',
      builder: (_) => const SuggestedHabitsSheet(),
    );

/// Suggested starter habits. Nothing is pre-selected.
class SuggestedHabitsSheet extends ConsumerStatefulWidget {
  const SuggestedHabitsSheet({super.key});

  @override
  ConsumerState<SuggestedHabitsSheet> createState() =>
      _SuggestedHabitsSheetState();
}

class _SuggestedHabitsSheetState extends ConsumerState<SuggestedHabitsSheet> {
  final _selected = <int>{};
  bool _saving = false;

  Future<void> _add() async {
    setState(() => _saving = true);
    final repo = ref.read(habitRepositoryProvider);
    for (final i in _selected.toList()..sort()) {
      final t = suggestedHabits[i];
      await repo.create(
        HabitInput(
          name: t.name,
          category: t.category,
          schedule: t.schedule,
          autoRule: t.autoRule,
          reminderTimes: t.reminderTimes,
        ),
      );
    }
    if (!mounted) return;
    Haptics.success();
    final n = _selected.length;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger?.showSnackBar(
      SnackBar(content: Text('Added $n ${n == 1 ? 'habit' : 'habits'}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final maxH = MediaQuery.sizeOf(context).height * 0.62;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pick only what fits your life right now. You can edit, archive or '
          'skip any of them later.',
          style: t.bodyMedium?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.md),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0, 0.04, 0.94, 1],
            ).createShader(r),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: suggestedHabits.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, i) => Entrance(
                delay: AppMotion.staggerStep * (i < 8 ? i : 8),
                child: SuggestedHabitTile(
                  key: Key('suggested-$i'),
                  template: suggestedHabits[i],
                  selected: _selected.contains(i),
                  onTap: () => setState(
                    () => _selected.contains(i)
                        ? _selected.remove(i)
                        : _selected.add(i),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        HudButton(
          label: _selected.isEmpty
              ? 'Select habits to add'
              : 'Add ${_selected.length} '
                    '${_selected.length == 1 ? 'habit' : 'habits'}',
          expand: true,
          loading: _saving,
          onPressed: _selected.isEmpty || _saving ? null : _add,
        ),
      ],
    );
  }
}

/// One template: category glyph, name, schedule and note, with a check node
/// that floods when selected.
class SuggestedHabitTile extends StatelessWidget {
  const SuggestedHabitTile({
    super.key,
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final HabitTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final tpl = template;
    return Semantics(
      button: true,
      checked: selected,
      label: tpl.name,
      hint: tpl.schedule.describe(),
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.98,
        child: AnimatedContainer(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: selected
                ? AppColors.habit.withValues(alpha: 0.10)
                : hud.glassFill,
            border: Border.all(
              color: selected
                  ? AppColors.habit.withValues(alpha: 0.6)
                  : hud.hairline.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            children: [
              HabitCheckNode(
                state: selected ? HabitNodeState.done : HabitNodeState.open,
                size: 32,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tpl.name, style: t.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      [
                        tpl.schedule.describe(),
                        tpl.category.label,
                      ].join(' · ').toUpperCase(),
                      style: hud.label(size: 10.5),
                    ),
                    if (tpl.note != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        tpl.note!,
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              if (tpl.autoRule != null)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: Tooltip(
                    message: 'Completes automatically',
                    child: Icon(Icons.bolt, size: 16, color: hud.accentInk),
                  ),
                ),
              if (tpl.reminderTimes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: Text(
                    tpl.reminderTimes.map(formatMinutes).join(' '),
                    style: hud.mono(size: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
