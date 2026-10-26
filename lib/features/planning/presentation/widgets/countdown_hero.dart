import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/planning_providers.dart';
import '../../domain/countdown.dart';

/// Gold text that stays legible on porcelain.
Color _goldInk(BuildContext context) =>
    context.hud.isDark ? AppColors.gold : AppColors.goldInk;

/// The competition countdown as a gold arc reactor: days in the core, prep
/// progress on the ring, event facts underneath.
class CountdownHero extends StatelessWidget {
  const CountdownHero({
    super.key,
    required this.view,
    this.onTap,
    this.large = false,
  });

  final CompetitionView view;
  final VoidCallback? onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final gold = _goldInk(context);
    final c = view.countdown;
    final comp = view.competition;
    final eventDate = DateTime(
      c.eventDate.year,
      c.eventDate.month,
      c.eventDate.day,
    );
    final bigNumber = switch (c.phase) {
      CountdownPhase.upcoming => '${c.daysRemaining}',
      CountdownPhase.today => '0',
      CountdownPhase.past => '${c.daysSince}',
    };
    final bigLabel = switch (c.phase) {
      CountdownPhase.upcoming =>
        c.daysRemaining == 1 ? 'DAY TO GO' : 'DAYS TO GO',
      CountdownPhase.today => 'SHOW DAY',
      CountdownPhase.past => c.daysSince == 1 ? 'DAY SINCE' : 'DAYS SINCE',
    };
    final semantics = switch (c.phase) {
      CountdownPhase.upcoming =>
        '${comp.name}: ${c.daysRemaining} days to go, ${c.weeksAndDaysLabel}',
      CountdownPhase.today => '${comp.name} is today',
      CountdownPhase.past => '${comp.name} was ${c.daysSince} days ago',
    };
    final size = large ? 210.0 : 150.0;

    Widget meta(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: hud.textMuted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: t.labelMedium?.copyWith(color: hud.textMuted),
          ),
        ),
      ],
    );

    return Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      onTap: onTap,
      child: AppCard(
        accent: AppColors.gold,
        brackets: true,
        glow: c.phase == CountdownPhase.today,
        onTap: onTap,
        child: Column(
          children: [
            Row(
              children: [
                const GlowIcon(
                  Icons.emoji_events_outlined,
                  size: 16,
                  color: AppColors.gold,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    comp.name.toUpperCase(),
                    style: hud.label(size: 12, color: gold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onTap != null)
                  Icon(Icons.chevron_right, color: hud.textMuted),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Hero(
              tag: 'competition-ring-${comp.id}',
              child: ProgressRing(
                progress: c.progress ?? 0,
                color: AppColors.gold,
                size: size,
                stroke: large ? 10 : 8,
                celebrate: false,
                semanticLabel: 'Prep progress',
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedTicker(
                      bigNumber,
                      style: hud.number(size: large ? 60 : 44),
                    ),
                    Text(bigLabel, style: hud.label(size: 11, color: gold)),
                    if (c.phase == CountdownPhase.upcoming) ...[
                      const SizedBox(height: 2),
                      Text(
                        c.weeksAndDaysLabel,
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (c.phase == CountdownPhase.today) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'Show day. Trust the work.',
                style: t.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                meta(
                  Icons.event,
                  DateFormat('EEE d MMM yyyy').format(eventDate),
                ),
                meta(
                  Icons.public,
                  c.usedFallbackTz
                      ? 'Device timezone (stored zone invalid)'
                      : c.effectiveTzName ?? comp.tzName,
                ),
                if (comp.location != null)
                  meta(Icons.place_outlined, comp.location!),
                if (comp.division != null)
                  meta(Icons.category_outlined, comp.division!),
              ],
            ),
            if (c.progress != null) ...[
              const SizedBox(height: AppSpacing.lg),
              PrepPhaseBar(countdown: c),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${(c.progress! * 100).round()}% of prep complete'
                '${c.totalPrepDays != null ? ' · ${c.totalPrepDays}-day prep' : ''}',
                style: hud.mono(size: 10.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A guide to the prep phases across the prep window, with a marker for
/// today. Purely calendar-based; it never prescribes peak-week tactics.
class PrepPhaseBar extends StatelessWidget {
  const PrepPhaseBar({super.key, required this.countdown});
  final CountdownResult countdown;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = countdown;
    final total = c.totalPrepDays;
    if (total == null || total <= 0) return const SizedBox.shrink();
    // Final 2 weeks, the 10 before that, and everything earlier.
    final last = (14 / total).clamp(0.0, 1.0);
    final cut = (84 / total).clamp(0.0, 1.0 - last);
    final build = (1 - last - cut).clamp(0.0, 1.0);
    final phases = [
      if (build > 0.02)
        ('BUILD', build, AppColors.gold.withValues(alpha: 0.45)),
      ('CUT', cut, AppColors.gold.withValues(alpha: 0.75)),
      ('FINAL 2 WK', last, AppColors.gold),
    ];
    final p = (c.progress ?? 0).clamp(0.0, 1.0);
    return Semantics(
      label: 'Prep phases guide, ${(p * 100).round()} percent through',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return Column(
            children: [
              SizedBox(
                height: 14,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      top: 4,
                      bottom: 4,
                      child: Row(
                        children: [
                          for (var i = 0; i < phases.length; i++)
                            Expanded(
                              flex: (phases[i].$2 * 1000).round().clamp(
                                1,
                                1000,
                              ),
                              child: Container(
                                margin: EdgeInsets.only(
                                  right: i == phases.length - 1 ? 0 : 2,
                                ),
                                decoration: BoxDecoration(
                                  color: phases[i].$3.withValues(
                                    alpha: phases[i].$3.a * 0.6,
                                  ),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: (w * p - 1).clamp(0.0, w - 2),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          color: hud.text,
                          boxShadow: [
                            BoxShadow(
                              color: hud.text.withValues(alpha: 0.7),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 12,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < phases.length; i++)
                      if (i == phases.length - 1)
                        Positioned(
                          right: 0,
                          child: Text(
                            phases[i].$1,
                            style: hud.label(size: 8.5),
                          ),
                        )
                      else
                        Positioned(
                          left:
                              w *
                              phases
                                  .take(i)
                                  .fold<double>(0, (a, p) => a + p.$2),
                          child: Text(
                            phases[i].$1,
                            style: hud.label(size: 8.5),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Compact gold call to action shown when no competition is set.
class CompetitionCta extends StatelessWidget {
  const CompetitionCta({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Semantics(
      button: true,
      label: 'Set your competition date',
      excludeSemantics: true,
      onTap: onTap,
      child: AppCard(
        accent: AppColors.gold,
        onTap: onTap,
        child: Row(
          children: [
            const GlowIcon(
              Icons.emoji_events_outlined,
              color: AppColors.gold,
              size: 22,
              framed: true,
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Set your competition date', style: t.titleMedium),
                  Text(
                    'Start a countdown, prep phases and a checklist. No date '
                    'yet is fine.',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: hud.textMuted),
          ],
        ),
      ),
    );
  }
}
