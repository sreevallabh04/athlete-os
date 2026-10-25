import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../application/persona_providers.dart';
import '../domain/daily_routine.dart';
import 'program_screen.dart';
import 'routine_screen.dart';

/// Today-screen section: planned session (Hero to the program screen) and
/// the routine block in progress. Empty until JARVIS calibration has run.
class PersonaTodaySection extends ConsumerWidget {
  const PersonaTodaySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(todaysRoutineProvider).value;
    final session = ref.watch(todaysPlannedSessionProvider).value;
    if (blocks == null && session == null) return const SizedBox.shrink();
    final now = ref.watch(clockProvider).now();
    final minute = now.hour * 60 + now.minute;
    final current = blocks == null ? null : currentBlock(blocks, minute);
    final next = blocks?.where((b) => b.start > minute).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlannedSessionCard(hero: true),
        if (blocks != null) ...[
          _NowNextCard(current: current, next: next),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

class _NowNextCard extends StatelessWidget {
  const _NowNextCard({required this.current, required this.next});
  final RoutineBlock? current;
  final RoutineBlock? next;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget line(String label, RoutineBlock b) => Row(
      children: [
        Icon(routineIcon(b.kind), size: 18, color: routineColor(b.kind)),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '$label ',
          style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Expanded(
          child: Text(
            '${b.title} · ${b.timeLabel}',
            style: t.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return AppCard(
      onTap: () => context.push(AppPaths.routine),
      semanticLabel: 'Your routine',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: AnimatedSize(
        duration: AppDurations.medium,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Your day', style: t.titleSmall)),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (current != null) line('Now', current!),
            if (next != null) ...[
              const SizedBox(height: AppSpacing.xs),
              line('Next', next!),
            ],
            if (current == null && next == null)
              Text('Day complete. Rest well.', style: t.bodyMedium),
          ],
        ),
      ),
    );
  }
}
