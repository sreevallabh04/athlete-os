import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../application/persona_providers.dart';
import '../data/nutrition_adjustment_service.dart';
import '../domain/daily_routine.dart';
import '../domain/nutrition_calculator.dart';

/// Today's routine timeline + nutrition targets and weekly check-in.
class RoutineScreen extends ConsumerWidget {
  const RoutineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routine = ref.watch(todaysRoutineProvider);
    final now = ref.watch(clockProvider).now();
    final minute = now.hour * 60 + now.minute;
    return AppPage(
      title: 'Your day',
      subtitle: 'Generated from your schedule — a guide, not a rule.',
      children: [
        routine.when(
          loading: () => const LoadingState(),
          error: (e, _) =>
              const ErrorState(message: 'Could not build routine.'),
          data: (blocks) => blocks == null
              ? AppCard(
                  child: EmptyState(
                    icon: Icons.view_timeline_outlined,
                    title: 'No routine yet',
                    message: 'Run JARVIS calibration first.',
                    actionLabel: 'Calibrate',
                    onAction: () => context.push(AppPaths.onboarding),
                  ),
                )
              : RoutineTimeline(blocks: blocks, nowMinute: minute),
        ),
        const SectionHeader('Nutrition'),
        const NutritionCheckInCard(),
      ],
    );
  }
}

IconData routineIcon(RoutineKind k) => switch (k) {
  RoutineKind.wake => Icons.wb_twilight,
  RoutineKind.training => Icons.fitness_center,
  RoutineKind.meal => Icons.restaurant,
  RoutineKind.commute => Icons.directions_transit,
  RoutineKind.office => Icons.work_outline,
  RoutineKind.focus => Icons.center_focus_strong,
  RoutineKind.walk => Icons.directions_walk,
  RoutineKind.ritual => Icons.self_improvement,
  RoutineKind.personal => Icons.home_outlined,
  RoutineKind.windDown => Icons.nightlight_outlined,
  RoutineKind.sleep => Icons.bedtime_outlined,
};

Color routineColor(RoutineKind k) => switch (k) {
  RoutineKind.training => AppColors.strength,
  RoutineKind.meal => AppColors.protein,
  RoutineKind.walk => AppColors.steps,
  RoutineKind.focus => AppColors.info,
  RoutineKind.office => AppColors.brand,
  RoutineKind.ritual => AppColors.mood,
  RoutineKind.sleep || RoutineKind.windDown => AppColors.sleep,
  _ => AppColors.brandAlt,
};

class RoutineTimeline extends StatelessWidget {
  const RoutineTimeline({
    super.key,
    required this.blocks,
    required this.nowMinute,
    this.maxItems,
  });

  final List<RoutineBlock> blocks;
  final int nowMinute;
  final int? maxItems;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final current = currentBlock(blocks, nowMinute);
    var list = blocks;
    if (maxItems != null) {
      final from = blocks.indexWhere((b) => b.end > nowMinute);
      list = blocks
          .skip(from < 0 ? blocks.length : from)
          .take(maxItems!)
          .toList();
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        children: [
          if (list.isEmpty)
            Text(
              'Day complete. Rest well.',
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          for (var i = 0; i < list.length; i++)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 240 + 40 * i.clamp(0, 10)),
              curve: Curves.easeOutCubic,
              builder: (context, v, child) => Opacity(opacity: v, child: child),
              child: _BlockRow(
                block: list[i],
                active: identical(list[i], current),
                last: i == list.length - 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.block,
    required this.active,
    required this.last,
  });

  final RoutineBlock block;
  final bool active;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = routineColor(block.kind);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                block.timeLabel.split('–').first,
                style: t.labelMedium?.copyWith(
                  color: active ? c : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w700 : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.sm),
                AnimatedContainer(
                  duration: AppDurations.medium,
                  width: active ? 14 : 10,
                  height: active ? 14 : 10,
                  decoration: BoxDecoration(
                    color: active ? c : c.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: c.withValues(alpha: 0.5),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(width: 2, color: scheme.outlineVariant),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: block.atOffice ? AppSpacing.md : 0,
                top: AppSpacing.xs,
                bottom: AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(routineIcon(block.kind), size: 16, color: c),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          block.title,
                          style: t.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    block.timeLabel,
                    style: t.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (block.detail != null)
                    Text(
                      block.detail!,
                      style: t.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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

/// Compact "up next" routine section for Planner/Today. Renders nothing until
/// calibration has run.
class RoutineSection extends ConsumerWidget {
  const RoutineSection({super.key, this.maxItems = 4});
  final int maxItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(todaysRoutineProvider).value;
    if (blocks == null) return const SizedBox.shrink();
    final now = ref.watch(clockProvider).now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Routine',
          subtitle: 'Up next from your JARVIS day plan',
          action: 'Full day',
          onAction: () => context.push(AppPaths.routine),
        ),
        RoutineTimeline(
          blocks: blocks,
          nowMinute: now.hour * 60 + now.minute,
          maxItems: maxItems,
        ),
      ],
    );
  }
}

/// Current targets + weekly trend check + pending kcal proposals.
class NutritionCheckInCard extends ConsumerStatefulWidget {
  const NutritionCheckInCard({super.key});

  @override
  ConsumerState<NutritionCheckInCard> createState() =>
      _NutritionCheckInCardState();
}

class _NutritionCheckInCardState extends ConsumerState<NutritionCheckInCard> {
  KcalAdjustment? _last;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(nutritionAdjustmentServiceProvider).evaluate();
      if (mounted) setState(() => _last = r);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).value;
    final pending =
        ref.watch(pendingNutritionAdjustmentsProvider).value ??
        const <AiRecommendation>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (profile != null)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${profile.calorieTarget} kcal · '
                  '${profile.proteinTargetG.round()} P · '
                  '${profile.carbsTargetG.round()} C · '
                  '${profile.fatTargetG.round()} F',
                  style: t.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  NutritionPlan.disclaimer,
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.monitor_weight_outlined),
                  label: const Text('Run weekly check-in'),
                ),
                if (_last != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_last!.message, style: t.bodySmall),
                ],
              ],
            ),
          ),
        for (final r in pending) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            accent: AppColors.calories,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: AppColors.calories,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text('JARVIS recommendation', style: t.titleSmall),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(r.content, style: t.bodyMedium),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => ref
                          .read(nutritionAdjustmentServiceProvider)
                          .dismiss(r.id),
                      child: const Text('Dismiss'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () => ref
                          .read(nutritionAdjustmentServiceProvider)
                          .accept(r.id),
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
