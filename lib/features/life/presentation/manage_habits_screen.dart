import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import 'habits_screen.dart';

/// Reorder active habits (drag handle) and manage archived ones.
class ManageHabitsScreen extends ConsumerWidget {
  const ManageHabitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(allHabitsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage habits')),
      body: all.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Habits couldn\'t be loaded.',
          onRetry: () => ref.invalidate(allHabitsProvider),
        ),
        data: (habits) {
          final active = habits.where((h) => !h.archived).toList();
          final archived = habits.where((h) => h.archived).toList();
          if (habits.isEmpty) {
            return const EmptyState(
              icon: Icons.checklist_rtl,
              title: 'No habits yet',
            );
          }
          return CustomScrollView(
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                sliver: SliverToBoxAdapter(
                  child: SectionHeader(
                    'Active',
                    subtitle: 'Drag to change the order on your checklist',
                  ),
                ),
              ),
              SliverReorderableList(
                itemCount: active.length,
                onReorderItem: (from, to) {
                  // `to` is already adjusted for the removed item.
                  final ids = active.map((h) => h.id).toList();
                  final moved = ids.removeAt(from);
                  ids.insert(to, moved);
                  ref.read(habitRepositoryProvider).reorder(ids);
                },
                itemBuilder: (context, i) {
                  final h = active[i];
                  return Material(
                    key: ValueKey(h.id),
                    type: MaterialType.transparency,
                    child: ListTile(
                      title: Text(h.name),
                      subtitle: Text(scheduleOf(h).describe()),
                      onTap: () => openHabitEditor(context, habit: h),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Archive ${h.name}',
                            icon: const Icon(Icons.archive_outlined),
                            onPressed: () => ref
                                .read(habitRepositoryProvider)
                                .setArchived(h.id, true),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (archived.isNotEmpty) ...[
                const SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                  sliver: SliverToBoxAdapter(
                    child: SectionHeader(
                      'Archived',
                      subtitle: 'History is kept; restore any time',
                    ),
                  ),
                ),
                SliverList.list(
                  children: [
                    for (final Habit h in archived)
                      ListTile(
                        title: Text(h.name),
                        subtitle: Text(scheduleOf(h).describe()),
                        trailing: TextButton(
                          onPressed: () => ref
                              .read(habitRepositoryProvider)
                              .setArchived(h.id, false),
                          child: const Text('Restore'),
                        ),
                      ),
                  ],
                ),
              ],
              const SliverToBoxAdapter(
                child: SizedBox(height: AppSpacing.xxxl),
              ),
            ],
          );
        },
      ),
    );
  }
}
