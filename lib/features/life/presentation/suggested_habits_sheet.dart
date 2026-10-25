import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../data/habit_repository.dart';
import '../domain/suggested_habits.dart';

Future<void> showSuggestedHabitsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Suggested habits', style: t.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Pick only what fits your life right now. You can edit, '
                  'archive or skip any of them later.',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              children: [
                for (var i = 0; i < suggestedHabits.length; i++)
                  CheckboxListTile(
                    value: _selected.contains(i),
                    onChanged: (v) => setState(
                      () => v == true ? _selected.add(i) : _selected.remove(i),
                    ),
                    title: Text(suggestedHabits[i].name),
                    subtitle: Text(
                      [
                        suggestedHabits[i].schedule.describe(),
                        if (suggestedHabits[i].note != null)
                          suggestedHabits[i].note!,
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty || _saving ? null : _add,
                  child: Text(
                    _selected.isEmpty
                        ? 'Select habits to add'
                        : 'Add ${_selected.length} '
                              '${_selected.length == 1 ? 'habit' : 'habits'}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
