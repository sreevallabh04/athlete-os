import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../application/planning_providers.dart';
import '../../domain/countdown.dart';

/// Gradient hero showing the competition countdown. Used on Today (compact)
/// and on the competition screen (large).
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
    final t = Theme.of(context).textTheme;
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
        c.daysRemaining == 1 ? 'day to go' : 'days to go',
      CountdownPhase.today => 'Show day — good luck!',
      CountdownPhase.past => c.daysSince == 1 ? 'day since' : 'days since',
    };
    const onHero = Colors.white;
    final sub = onHero.withValues(alpha: 0.82);
    final semantics = switch (c.phase) {
      CountdownPhase.upcoming =>
        '${comp.name}: ${c.daysRemaining} days to go, ${c.weeksAndDaysLabel}',
      CountdownPhase.today => '${comp.name} is today',
      CountdownPhase.past => '${comp.name} was ${c.daysSince} days ago',
    };

    return Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          gradient: AppGradients.competition,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          boxShadow: [
            BoxShadow(
              color: AppColors.competition.withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.xl),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.all(
                large ? AppSpacing.xl : AppSpacing.lg + 4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.emoji_events_outlined,
                        color: onHero,
                        size: 18,
                      ),
                      const SizedBox(width: AppSpacing.xs + 2),
                      Expanded(
                        child: Text(
                          comp.name,
                          style: t.titleSmall?.copyWith(
                            color: onHero,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (onTap != null) Icon(Icons.chevron_right, color: sub),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        bigNumber,
                        style: (large ? t.displayLarge : t.displayMedium)
                            ?.copyWith(
                              color: onHero,
                              fontWeight: FontWeight.w800,
                              height: 1,
                              letterSpacing: -1.5,
                            ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bigLabel,
                                style: t.titleMedium?.copyWith(color: onHero),
                              ),
                              if (c.phase == CountdownPhase.upcoming)
                                Text(
                                  c.weeksAndDaysLabel,
                                  style: t.bodySmall?.copyWith(color: sub),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.xs,
                    children: [
                      _meta(
                        Icons.event,
                        DateFormat('EEE d MMM yyyy').format(eventDate),
                        sub,
                        t,
                      ),
                      _meta(
                        Icons.public,
                        c.usedFallbackTz
                            ? 'Device timezone (stored zone invalid)'
                            : c.effectiveTzName ?? comp.tzName,
                        sub,
                        t,
                      ),
                      if (comp.location != null)
                        _meta(Icons.place_outlined, comp.location!, sub, t),
                      if (comp.division != null)
                        _meta(Icons.category_outlined, comp.division!, sub, t),
                    ],
                  ),
                  if (c.progress != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: c.progress!),
                        duration: AppDurations.slow,
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 6,
                          color: onHero,
                          backgroundColor: onHero.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${(c.progress! * 100).round()}% of prep complete'
                      '${c.totalPrepDays != null ? ' · ${c.totalPrepDays}-day prep' : ''}',
                      style: t.labelSmall?.copyWith(color: sub),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text, Color color, TextTheme t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: t.labelMedium?.copyWith(color: color),
        ),
      ),
    ],
  );
}

/// Call to action shown when no competition is set.
class CompetitionCta extends StatelessWidget {
  const CompetitionCta({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Set your competition date',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(AppSpacing.lg + 4),
            decoration: BoxDecoration(
              gradient: AppGradients.subtle(AppColors.competition),
              borderRadius: BorderRadius.circular(AppRadii.xl),
              border: Border.all(
                color: AppColors.competition.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(
                    gradient: AppGradients.competition,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.emoji_events, color: Colors.white),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Set your competition date', style: t.titleMedium),
                      Text(
                        'Start a countdown, milestones and a prep checklist.',
                        style: t.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
