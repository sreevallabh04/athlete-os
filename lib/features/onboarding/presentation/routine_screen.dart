import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../application/persona_providers.dart';
import '../data/nutrition_adjustment_service.dart';
import '../domain/calibration.dart' show hhmm;
import '../domain/daily_routine.dart';
import '../domain/nutrition_calculator.dart';

/// Today's routine as a vertical HUD timeline with a live "now" line, plus
/// nutrition targets and the weekly check-in.
class RoutineScreen extends ConsumerWidget {
  const RoutineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routine = ref.watch(todaysRoutineProvider);
    final now = ref.watch(clockProvider).now();
    final minute = now.hour * 60 + now.minute;
    return AppPage(
      title: 'Your day',
      eyebrow:
          '${DateFormat('EEE d MMM').format(now).toUpperCase()} · '
          'NOW ${hhmm(minute)}',
      subtitle: 'Built from your schedule. A guide, not a rule.',
      children: [
        routine.when(
          loading: () => const AppCard(child: ScanlineLoader(lines: 6)),
          error: (e, _) =>
              const ErrorState(message: 'Could not build your routine.'),
          data: (blocks) => blocks == null
              ? AppCard(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.view_timeline_outlined,
                    title: 'No routine yet',
                    message:
                        'Calibrate once and I will lay out training, meals, '
                        'focus blocks and wind-down around your hours.',
                    actionLabel: 'Calibrate JARVIS',
                    onAction: () => context.push(AppPaths.onboarding),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DayStats(blocks: blocks),
                    const SizedBox(height: AppSpacing.md),
                    RoutineTimeline(blocks: blocks, nowMinute: minute),
                  ],
                ),
        ),
        if (!routine.isLoading) ...[
          const SectionHeader('Nutrition'),
          const NutritionCheckInCard(),
        ],
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

/// Slate for neutral blocks (commute, personal time).
const _slate = Color(0xFF8EA3B8);

Color routineColor(RoutineKind k) => switch (k) {
  RoutineKind.training => AppColors.strength,
  RoutineKind.meal => AppColors.protein,
  RoutineKind.walk => AppColors.steps,
  RoutineKind.focus => AppColors.cyan,
  RoutineKind.office => AppColors.cyanDeep,
  RoutineKind.ritual => AppColors.mood,
  RoutineKind.sleep || RoutineKind.windDown => AppColors.sleep,
  RoutineKind.wake => AppColors.water,
  RoutineKind.commute || RoutineKind.personal => _slate,
};

class _DayStats extends StatelessWidget {
  const _DayStats({required this.blocks});
  final List<RoutineBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final training = blocks
        .where((b) => b.kind == RoutineKind.training)
        .firstOrNull;
    final meals = blocks.where((b) => b.kind == RoutineKind.meal).toList();
    final protein = meals.fold<int>(0, (s, b) => s + (b.proteinG ?? 0));
    final focus = blocks.where((b) => b.kind == RoutineKind.focus).length;
    final first = blocks.first.start;
    final sleep = blocks.where((b) => b.kind == RoutineKind.sleep).firstOrNull;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: StatTile(
              label: 'Train',
              value: training == null ? '—' : hhmm(training.start),
              color: AppColors.strength,
            ),
          ),
          Expanded(
            child: StatTile(
              label: 'Meals',
              value: '${meals.length}',
              sub: protein > 0 ? '~$protein g P' : null,
              color: AppColors.protein,
            ),
          ),
          Expanded(
            child: StatTile(
              label: 'Focus',
              value: '$focus',
              sub: focus == 1 ? 'block' : 'blocks',
              color: AppColors.cyan,
            ),
          ),
          Expanded(
            child: StatTile(
              label: 'Window',
              value: hhmm(first),
              sub: sleep == null ? null : 'to ${hhmm(sleep.start)}',
              color: AppColors.sleep,
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertical HUD timeline. Past blocks dim, the block in progress glows with
/// an elapsed bar, and a "now" line sits between blocks when nothing is in
/// progress.
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
    final hud = context.hud;
    final current = currentBlock(blocks, nowMinute);
    var list = blocks;
    if (maxItems != null) {
      final from = blocks.indexWhere((b) => b.end > nowMinute);
      list = blocks
          .skip(from < 0 ? blocks.length : from)
          .take(maxItems!)
          .toList();
    }
    final nowIndex = current != null
        ? -1
        : list.indexWhere((b) => b.start > nowMinute);
    final rows = <Widget>[
      for (var i = 0; i < list.length; i++) ...[
        if (i == nowIndex) NowLine(minute: nowMinute),
        RoutineRow(
          block: list[i],
          active: identical(list[i], current),
          nowMinute: nowMinute,
          last: i == list.length - 1,
        ),
      ],
    ];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: list.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                'Day complete. Rest well.',
                style: t.bodyMedium?.copyWith(color: hud.textMuted),
              ),
            )
          : StaggeredList(children: rows),
    );
  }
}

/// The glowing "now" marker between routine blocks.
class NowLine extends StatelessWidget {
  const NowLine({super.key, required this.minute});
  final int minute;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      label: 'Now, ${hhmm(minute)}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(
                hhmm(minute),
                style: hud
                    .mono(size: 10.5, color: hud.accentInk)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(
              width: 22,
              child: Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: hud.accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: hud.accent.withValues(
                          alpha: 0.9 * hud.glowStrength,
                        ),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1.4,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [hud.accent, hud.accent.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('NOW', style: hud.label(size: 10, color: hud.accentInk)),
          ],
        ),
      ),
    );
  }
}

/// One routine block on the rail.
class RoutineRow extends StatelessWidget {
  const RoutineRow({
    super.key,
    required this.block,
    required this.active,
    required this.nowMinute,
    required this.last,
    this.compact = false,
  });

  final RoutineBlock block;
  final bool active;
  final int nowMinute;
  final bool last;

  /// Today peek: one-line detail, tighter spacing.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final c = routineColor(block.kind);
    final past = block.end <= nowMinute;
    final elapsed = active
        ? ((nowMinute - block.start) / block.minutes).clamp(0.0, 1.0)
        : 0.0;
    final node = AnimatedContainer(
      duration: AppMotion.medium,
      width: active ? 12 : 9,
      height: active ? 12 : 9,
      decoration: BoxDecoration(
        color: active || !past ? c : null,
        shape: BoxShape.circle,
        border: past && !active ? Border.all(color: c, width: 1.4) : null,
        boxShadow: active
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.85 * hud.glowStrength),
                  blurRadius: 10,
                ),
              ]
            : null,
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(routineIcon(block.kind), size: 15, color: c),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                block.title,
                style: t.titleSmall,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (active) ...[
              const SizedBox(width: AppSpacing.xs),
              HudChip(label: 'Now', color: c, selected: true),
            ] else if (block.atOffice) ...[
              const SizedBox(width: AppSpacing.xs),
              Text('AT DESK', style: hud.mono(size: 9)),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          compact || block.detail == null
              ? block.timeLabel
              : '${block.timeLabel} · ${block.detail}',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
          maxLines: compact ? 1 : 3,
          overflow: TextOverflow.ellipsis,
        ),
        if (compact && block.detail != null)
          Text(
            block.detail!,
            style: t.bodySmall?.copyWith(color: hud.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (active) ...[
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 4,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: elapsed),
              duration: AppMotion.reduced(context)
                  ? Duration.zero
                  : AppMotion.data,
              curve: AppMotion.emphasizedDecelerate,
              builder: (_, v, _) => CustomPaint(
                painter: SegmentedBarPainter(
                  value: v,
                  color: c,
                  hud: hud,
                  segments: 0,
                ),
              ),
            ),
          ),
        ],
      ],
    );
    return Semantics(
      label:
          '${block.title}, ${block.timeLabel}${active ? ', in progress' : ''}'
          '${past && !active ? ', done' : ''}',
      excludeSemantics: true,
      child: Opacity(
        opacity: past && !active ? 0.5 : 1,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 46,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    hhmm(block.start),
                    style: hud.mono(
                      size: 11,
                      color: active ? inkOf(context, c) : hud.textMuted,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 22,
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    node,
                    if (!last)
                      Expanded(
                        child: Container(
                          width: 1.2,
                          margin: const EdgeInsets.only(top: 3),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                c.withValues(alpha: past ? 0.5 : 0.35),
                                hud.hairline.withValues(alpha: 0.12),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Container(
                  margin: EdgeInsets.only(
                    left: block.atOffice ? AppSpacing.sm : 0,
                    bottom: compact ? AppSpacing.sm : AppSpacing.md,
                  ),
                  padding: active
                      ? const EdgeInsets.all(AppSpacing.sm + 2)
                      : EdgeInsets.zero,
                  decoration: active
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          color: c.withValues(alpha: 0.09),
                          border: Border.all(color: c.withValues(alpha: 0.3)),
                        )
                      : null,
                  child: content,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Metric hues are stroke colours; on porcelain, darken them for text.
Color inkOf(BuildContext context, Color c) =>
    context.hud.isDark ? c : Color.lerp(c, Colors.black, 0.45)!;

/// Compact "up next" routine section for the planner. Renders nothing until
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
          subtitle: 'Up next',
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
      Haptics.success();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final profile = ref.watch(profileProvider).value;
    final pending =
        ref.watch(pendingNutritionAdjustmentsProvider).value ??
        const <AiRecommendation>[];
    Widget macro(String label, String value, Color c) => Expanded(
      child: StatTile(label: label, value: value, color: c),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (profile != null)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    macro(
                      'kcal',
                      '${profile.calorieTarget}',
                      AppColors.calories,
                    ),
                    macro(
                      'Protein',
                      '${profile.proteinTargetG.round()} g',
                      AppColors.protein,
                    ),
                    macro(
                      'Carbs',
                      '${profile.carbsTargetG.round()} g',
                      AppColors.carbs,
                    ),
                    macro(
                      'Fat',
                      '${profile.fatTargetG.round()} g',
                      AppColors.fat,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  NutritionPlan.disclaimer,
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
                const SizedBox(height: AppSpacing.md),
                HudButton.secondary(
                  label: 'Run weekly check-in',
                  icon: Icons.monitor_weight_outlined,
                  loading: _busy,
                  onPressed: _busy ? null : _check,
                ),
                AnimatedSize(
                  duration: AppMotion.medium,
                  alignment: Alignment.topCenter,
                  child: _last == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: Text(_last!.message, style: t.bodySmall),
                        ),
                ),
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
                    const GlowIcon(
                      Icons.auto_awesome,
                      size: 16,
                      color: AppColors.calories,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text('JARVIS RECOMMENDATION', style: hud.label(size: 11)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(r.content, style: t.bodyMedium),
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    HudButton.ghost(
                      label: 'Dismiss',
                      compact: true,
                      onPressed: () => ref
                          .read(nutritionAdjustmentServiceProvider)
                          .dismiss(r.id),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    HudButton(
                      label: 'Accept',
                      compact: true,
                      onPressed: () async {
                        await ref
                            .read(nutritionAdjustmentServiceProvider)
                            .accept(r.id);
                        Haptics.success();
                      },
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
