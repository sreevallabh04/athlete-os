import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../today/presentation/widgets/deck.dart';
import '../application/persona_providers.dart';
import '../domain/calibration.dart' show hhmm;
import '../domain/daily_routine.dart';
import '../domain/training_program.dart';
import 'routine_screen.dart';

Color sessionColor(SessionKind k) => switch (k) {
  SessionKind.run => AppColors.running,
  SessionKind.recovery => AppColors.habit,
  SessionKind.lift => AppColors.strength,
};

IconData sessionIcon(SessionKind k) => switch (k) {
  SessionKind.run => Icons.directions_run,
  SessionKind.recovery => Icons.self_improvement,
  SessionKind.lift => Icons.fitness_center,
};

/// Today deck: the planned session from the program (Hero → program
/// screen). Shows a calibration CTA until a program exists.
class TodaySessionCard extends ConsumerWidget {
  const TodaySessionCard({super.key, this.loggedTitle, this.emphasize = false});

  /// Title of a workout already recorded today, if any.
  final String? loggedTitle;

  /// Morning: the start button becomes the primary action of the deck.
  final bool emphasize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final async = ref.watch(todaysPlannedSessionProvider);
    final s = async.value;
    if (s == null) {
      if (async.isLoading) {
        return const AppCard(child: ScanlineLoader(lines: 2));
      }
      return AppCard(
        onTap: () => context.push(AppPaths.onboarding),
        semanticLabel: 'No program yet. Calibrate JARVIS to build one.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DeckLabel(
              icon: Icons.fitness_center,
              label: 'TODAY\'S SESSION',
              color: AppColors.strength,
              chevron: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'No program yet. Calibrate once and I will plan every session, '
              'deloads included.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
          ],
        ),
      );
    }
    final day = s.day;
    final color = sessionColor(day.kind);
    final done = loggedTitle != null;
    final lighter = s.lighter;
    final stats = <(String, String)>[
      if (day.run != null) ...[
        ('MIN', '${day.run!.minutes}'),
        ('PACE', formatPaceRange(day.run!.paceMinS, day.run!.paceMaxS)),
      ] else ...[
        ('EXERCISES', '${day.exercises.length}'),
        ('SETS', '${day.totalSets}'),
        ('MIN', '~${day.minutes}'),
      ],
    ];
    final card = AppCard(
      accent: color,
      onTap: () => context.push(AppPaths.program),
      semanticLabel: done
          ? 'Session logged: $loggedTitle'
          : 'Planned session: ${day.title}. Open the program.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: sessionIcon(day.kind),
            label: 'TODAY\'S SESSION',
            color: color,
            chevron: true,
            trailing: DeckTelemetry(
              'WK ${s.week}${s.isDeload ? ' · DELOAD' : ''}',
              color: s.isDeload ? goldInk(context) : null,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            day.title,
            style: t.titleLarge?.copyWith(
              fontFamily: AppFonts.display,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (day.focus.isNotEmpty)
            Text(
              day.focus,
              style: t.bodySmall?.copyWith(color: hud.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              for (var i = 0; i < stats.length; i++) ...[
                if (i > 0)
                  Container(
                    width: 1,
                    height: 26,
                    margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    color: hud.hairline.withValues(alpha: 0.18),
                  ),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(stats[i].$1, style: hud.label(size: 9.5)),
                      const SizedBox(height: 2),
                      Text(
                        stats[i].$2,
                        style: hud.number(size: 19),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (!done && lighter != null) ...[
            const SizedBox(height: AppSpacing.md),
            _InlineNote(
              icon: Icons.battery_charging_full,
              color: AppColors.warning,
              text:
                  'Readiness is low (${s.readiness.reason}). A lighter '
                  'variant is ready in the program.',
            ),
          ],
          if (!done && s.warnings.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _InlineNote(
              icon: Icons.healing_outlined,
              color: AppColors.warning,
              text:
                  '${s.warnings.length} exercise'
                  '${s.warnings.length == 1 ? '' : 's'} adjusted for your '
                  'restrictions.',
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (done)
            Row(
              children: [
                const StatusDot(color: AppColors.success),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Logged: $loggedTitle',
                    style: t.labelLarge?.copyWith(
                      color: inkFor(context, AppColors.success),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else
            HudButton(
              label: day.run != null ? 'Start run' : 'Start session',
              icon: Icons.play_arrow_rounded,
              variant: emphasize
                  ? HudButtonVariant.primary
                  : HudButtonVariant.secondary,
              compact: !emphasize,
              expand: true,
              onPressed: () => context.push(AppPaths.program),
            ),
        ],
      ),
    );
    return Hero(tag: s.heroTag, child: card);
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: t.bodySmall)),
      ],
    );
  }
}

/// Today deck: the routine block in progress and the next ones, with a
/// glowing "now" line. Opens the full routine.
class RoutinePeekCard extends ConsumerWidget {
  const RoutinePeekCard({super.key, this.count = 3});
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final async = ref.watch(todaysRoutineProvider);
    final blocks = async.value;
    final now = ref.watch(clockProvider).now();
    final minute = now.hour * 60 + now.minute;
    if (blocks == null) {
      if (async.isLoading) {
        return const AppCard(child: ScanlineLoader(lines: 3));
      }
      return AppCard(
        onTap: () => context.push(AppPaths.onboarding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DeckLabel(
              icon: Icons.view_timeline_outlined,
              label: 'YOUR DAY',
              chevron: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Calibrate JARVIS and I will lay out your day around training, '
              'office hours and sleep.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
          ],
        ),
      );
    }
    final current = currentBlock(blocks, minute);
    final upcoming = blocks
        .where((b) => b.start > minute && !identical(b, current))
        .toList();
    final shown = [?current, ...upcoming].take(count).toList();
    return AppCard(
      onTap: () => context.push(AppPaths.routine),
      semanticLabel: 'Your routine. Open the full day.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: Icons.view_timeline_outlined,
            label: 'YOUR DAY',
            chevron: true,
            trailing: DeckTelemetry(
              shown.isEmpty ? 'COMPLETE' : 'NOW ${hhmm(minute)}',
              color: hud.accentInk,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (shown.isEmpty)
            Text(
              'Day complete. Rest well.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            )
          else ...[
            if (current == null) NowLine(minute: minute),
            for (var i = 0; i < shown.length; i++)
              RoutineRow(
                block: shown[i],
                active: identical(shown[i], current),
                nowMinute: minute,
                last: i == shown.length - 1,
                compact: true,
              ),
          ],
        ],
      ),
    );
  }
}
