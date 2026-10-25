import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/habit_providers.dart';
import '../application/mood_journal_providers.dart';
import '../domain/mood_stats.dart';
import 'mood_check_in_sheet.dart';
import 'widgets/life_widgets.dart';

/// Life tab hub: today's habits, mood and journal status, and links to
/// planning, competition prep, reports and settings.
class LifeScreen extends ConsumerWidget {
  const LifeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPage(
      title: 'Life',
      subtitle: 'Habits, mood and reflection — at your own pace.',
      showBack: false,
      children: [
        const SizedBox(height: AppSpacing.md),
        const _HabitsCard(),
        const SizedBox(height: AppSpacing.md),
        const _MoodCard(),
        const SizedBox(height: AppSpacing.md),
        const _JournalCard(),
        const SectionHeader('Plan & prepare'),
        _NavGrid(
          tiles: [
            _NavTile(
              icon: Icons.event_note_outlined,
              label: 'Planner',
              color: AppColors.info,
              onTap: () => context.push(AppPaths.planner),
            ),
            _NavTile(
              icon: Icons.emoji_events_outlined,
              label: 'Competition prep',
              color: AppColors.competition,
              onTap: () => context.push(AppPaths.competition),
            ),
            _NavTile(
              icon: Icons.insights_outlined,
              label: 'Reports',
              color: AppColors.brandAlt,
              onTap: () => context.push(AppPaths.reports),
            ),
            _NavTile(
              icon: Icons.notifications_outlined,
              label: 'Reminders',
              color: AppColors.warning,
              onTap: () => context.push(AppPaths.notificationSettings),
            ),
            _NavTile(
              icon: Icons.settings_outlined,
              label: 'Settings',
              color: AppColors.brand,
              onTap: () => context.push(AppPaths.settings),
            ),
          ],
        ),
      ],
    );
  }
}

class _HabitsCard extends ConsumerWidget {
  const _HabitsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final board = ref.watch(habitBoardProvider);
    return AppCard(
      accent: AppColors.habit,
      onTap: () => context.push(AppPaths.habits),
      child: board.when(
        loading: () => const SizedBox(height: 84, child: LoadingState()),
        error: (e, _) => const Text('Habits couldn\'t be loaded.'),
        data: (b) {
          if (b.habits.isEmpty) {
            return Row(
              children: [
                const Icon(
                  Icons.checklist_rtl,
                  size: 32,
                  color: AppColors.habit,
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('No habits yet', style: t.titleMedium),
                      Text(
                        'Add one or two that fit your day.',
                        style: t.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            );
          }
          final due = b.dueToday.length;
          final done = b.doneToday;
          return Row(
            children: [
              ProgressRing(
                progress: due == 0 ? 0 : done / due,
                color: AppColors.habit,
                size: 72,
                stroke: 8,
                center: Text('$done/$due', style: t.titleSmall),
                semanticLabel: 'Habits done today',
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Habits', style: t.titleMedium),
                    Text(
                      due == 0
                          ? 'Nothing scheduled today'
                          : b.remainingToday == 0
                          ? 'All done or skipped today'
                          : '$done done · ${b.remainingToday} remaining',
                      style: t.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          );
        },
      ),
    );
  }
}

class _MoodCard extends ConsumerWidget {
  const _MoodCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final mood = ref.watch(todayMoodProvider);
    return AppCard(
      accent: AppColors.mood,
      onTap: () => context.push(AppPaths.mood),
      child: mood.when(
        loading: () => const SizedBox(height: 48, child: LoadingState()),
        error: (e, _) => const Text('Mood couldn\'t be loaded.'),
        data: (e) => Row(
          children: [
            Icon(
              e == null ? Icons.mood_outlined : moodIcon(e.mood),
              size: 36,
              color: e == null ? scheme.onSurfaceVariant : moodColor(e.mood),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mood', style: t.titleMedium),
                  Text(
                    e == null
                        ? 'No check-in yet today'
                        : '${moodLabels[e.mood]} · ${Fmt.time(e.recordedAt)}',
                    style: t.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => showMoodCheckIn(context),
              child: Text(e == null ? 'Check in' : 'Update'),
            ),
          ],
        ),
      ),
    );
  }
}

class _JournalCard extends ConsumerWidget {
  const _JournalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final written = ref.watch(journalWrittenTodayProvider);
    return AppCard(
      accent: AppColors.sleep,
      onTap: () => context.push(AppPaths.journal),
      child: Row(
        children: [
          const Icon(
            Icons.menu_book_outlined,
            size: 32,
            color: AppColors.sleep,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Journal', style: t.titleMedium),
                Text(
                  written.when(
                    loading: () => '…',
                    error: (e, _) => 'Journal couldn\'t be loaded.',
                    data: (w) => w
                        ? 'Written today'
                        : 'Nothing written today — optional',
                  ),
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Icon(Icons.lock_outline, size: 18),
        ],
      ),
    );
  }
}

class _NavTile {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

class _NavGrid extends StatelessWidget {
  const _NavGrid({required this.tiles});
  final List<_NavTile> tiles;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth > 600 ? 3 : 2;
        final w = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: w,
                child: AppCard(
                  onTap: tile.onTap,
                  semanticLabel: tile.label,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(tile.icon, color: tile.color),
                      const SizedBox(height: AppSpacing.md),
                      Text(tile.label, style: t.titleSmall),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
