import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../data/habit_repository.dart';
import 'habits_screen.dart';
import 'widgets/life_widgets.dart';

/// Reorder active habits (drag the grip; haptic on lift and on drop) and
/// manage archived ones.
class ManageHabitsScreen extends ConsumerStatefulWidget {
  const ManageHabitsScreen({super.key});

  @override
  ConsumerState<ManageHabitsScreen> createState() => _ManageHabitsScreenState();
}

class _ManageHabitsScreenState extends ConsumerState<ManageHabitsScreen> {
  /// Optimistic order while a reorder is being written.
  List<String>? _order;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(allHabitsProvider);
    return AppPage(
      title: 'Manage habits',
      eyebrow: 'ORDER · ARCHIVE',
      children: all.when(
        loading: () => const [ScanlineLoader(lines: 4)],
        error: (e, _) => [
          ErrorState(
            message: 'Habits couldn\'t be loaded.',
            onRetry: () => ref.invalidate(allHabitsProvider),
          ),
        ],
        data: (habits) {
          if (habits.isEmpty) {
            return const [
              EmptyState(
                icon: Icons.checklist_rtl,
                color: AppColors.habit,
                title: 'No habits yet',
              ),
            ];
          }
          var active = habits.where((h) => !h.archived).toList();
          final order = _order;
          if (order != null) {
            final byId = {for (final h in active) h.id: h};
            final sorted = [for (final id in order) ?byId[id]];
            if (sorted.length == active.length) active = sorted;
          }
          final archived = habits.where((h) => h.archived).toList();
          return [
            const LifeSection(
              'Active',
              hint: 'Drag the grip to change your checklist order',
              accent: AppColors.habit,
            ),
            if (active.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.inventory_2_outlined,
                title: 'Everything is archived',
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: active.length,
                onReorderStart: (_) => Haptics.medium(),
                onReorderEnd: (_) => Haptics.light(),
                proxyDecorator: (child, index, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final v = Curves.easeOut.transform(animation.value);
                    return Transform.scale(
                      scale: lerpDouble(1, 1.03, v),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: AppRadii.card,
                          boxShadow: AppGlows.soft(
                            AppColors.habit,
                            strength: v * context.hud.glowStrength,
                          ),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Material(
                    type: MaterialType.transparency,
                    child: child,
                  ),
                ),
                onReorderItem: (from, to) {
                  // `to` is already adjusted for the removed item.
                  final ids = active.map((h) => h.id).toList();
                  final moved = ids.removeAt(from);
                  ids.insert(to, moved);
                  Haptics.success();
                  setState(() => _order = ids);
                  ref.read(habitRepositoryProvider).reorder(ids);
                },
                itemBuilder: (context, i) {
                  final h = active[i];
                  return Padding(
                    key: ValueKey(h.id),
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _HabitRow(
                      habit: h,
                      index: i,
                      onTap: () => openHabitEditor(context, habit: h),
                      trailing: [
                        IconButton(
                          tooltip: 'Archive ${h.name}',
                          icon: const Icon(Icons.archive_outlined),
                          onPressed: () {
                            Haptics.medium();
                            ref
                                .read(habitRepositoryProvider)
                                .setArchived(h.id, true);
                          },
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Tooltip(
                            message: 'Drag to reorder ${h.name}',
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Icon(
                                Icons.drag_indicator,
                                color: context.hud.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (archived.isNotEmpty) ...[
              const LifeSection(
                'Archived',
                hint: 'History is kept; restore any time',
              ),
              ...spaced([
                for (final Habit h in archived)
                  Opacity(
                    opacity: 0.75,
                    child: _HabitRow(
                      habit: h,
                      trailing: [
                        HudButton.ghost(
                          label: 'Restore',
                          compact: true,
                          onPressed: () {
                            Haptics.success();
                            ref
                                .read(habitRepositoryProvider)
                                .setArchived(h.id, false);
                          },
                        ),
                      ],
                    ),
                  ),
              ], gap: AppSpacing.sm),
            ],
          ];
        },
      ),
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({
    required this.habit,
    required this.trailing,
    this.index,
    this.onTap,
  });
  final Habit habit;
  final List<Widget> trailing;
  final int? index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      onTap: onTap,
      animateEntrance: false,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          if (index != null) ...[
            SizedBox(
              width: 26,
              child: Text(
                (index! + 1).toString().padLeft(2, '0'),
                style: hud.mono(size: 12),
              ),
            ),
          ],
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(habit.name, style: t.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    scheduleOf(habit).describe(),
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}
