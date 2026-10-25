import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/paths.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/daily_summary.dart';
import '../../domain/today_layout.dart';

/// Prompt prefilled in the coach composer by "Ask JARVIS". Nothing is sent
/// until the user taps send there.
const askJarvisPrompt =
    'Brief me on the rest of my day: what should I prioritise next?';

IconData summaryIcon(SummaryTopic t) => switch (t) {
  SummaryTopic.competition => Icons.emoji_events_outlined,
  SummaryTopic.steps => Icons.directions_walk,
  SummaryTopic.protein => Icons.egg_alt_outlined,
  SummaryTopic.calories => Icons.local_fire_department_outlined,
  SummaryTopic.water => Icons.water_drop_outlined,
  SummaryTopic.calendar => Icons.event_outlined,
  SummaryTopic.workout => Icons.fitness_center,
  SummaryTopic.sleep => Icons.bedtime_outlined,
};

Color summaryColor(SummaryTopic t) => switch (t) {
  SummaryTopic.competition => AppColors.gold,
  SummaryTopic.steps => AppColors.steps,
  SummaryTopic.protein => AppColors.protein,
  SummaryTopic.calories => AppColors.calories,
  SummaryTopic.water => AppColors.water,
  SummaryTopic.calendar => AppColors.cyan,
  SummaryTopic.workout => AppColors.strength,
  SummaryTopic.sleep => AppColors.sleep,
};

/// The sentence the strip leads with: the most useful line for this part of
/// the day. Deterministic.
SummaryLine? leadLine(DailySummary s, DayPhase phase) {
  final order = switch (phase) {
    DayPhase.morning => const [
      SummaryTopic.workout,
      SummaryTopic.calendar,
      SummaryTopic.sleep,
      SummaryTopic.protein,
      SummaryTopic.steps,
    ],
    DayPhase.day => const [
      SummaryTopic.protein,
      SummaryTopic.steps,
      SummaryTopic.calendar,
      SummaryTopic.water,
      SummaryTopic.workout,
    ],
    DayPhase.evening => const [
      SummaryTopic.protein,
      SummaryTopic.steps,
      SummaryTopic.calories,
      SummaryTopic.water,
      SummaryTopic.workout,
    ],
  };
  for (final topic in order) {
    final hit = s.lines.where((l) => l.topic == topic).firstOrNull;
    if (hit != null) return hit;
  }
  return s.lines.where((l) => l.topic != SummaryTopic.competition).firstOrNull;
}

/// Calm fallback when nothing has been logged or synced.
String idleBriefing(DayPhase phase) => switch (phase) {
  DayPhase.morning =>
    'Nothing logged yet. Your targets are set and standing by.',
  DayPhase.day =>
    'No data in yet today. Log a meal or water and I will '
        'keep the tally.',
  DayPhase.evening =>
    'A quiet day on the sensors. Log what you can before '
        'the evening review.',
};

/// One-line JARVIS briefing: the lead sentence types in; tap for the full
/// briefing sheet.
class BriefingStrip extends StatelessWidget {
  const BriefingStrip({
    super.key,
    required this.summary,
    required this.phase,
    required this.now,
  });

  final DailySummary summary;
  final DayPhase phase;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final lead = leadLine(summary, phase);
    final text = lead?.text ?? idleBriefing(phase);
    final more = summary.lines.length - (lead == null ? 0 : 1);
    return Semantics(
      button: true,
      label: 'JARVIS briefing: $text. Open the full briefing.',
      excludeSemantics: true,
      onTap: () => showBriefingSheet(context, summary: summary, now: now),
      child: PressableScale(
        onTap: () => showBriefingSheet(context, summary: summary, now: now),
        pressedScale: 0.98,
        child: GlassPanel(
          accent: hud.accent,
          radius: AppRadii.lg,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: JarvisOrb(size: 34, fps: 30, semanticLabel: null),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'JARVIS · BRIEFING',
                          style: hud.mono(size: 9.5, color: hud.accentInk),
                        ),
                        const Spacer(),
                        if (more > 0)
                          Text(
                            '+$more',
                            style: hud.mono(size: 9.5, color: hud.textMuted),
                          ),
                        Icon(Icons.unfold_more, size: 14, color: hud.textMuted),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Typewriter(
                      text,
                      key: ValueKey(text),
                      style: t.bodyMedium?.copyWith(height: 1.4),
                      caret: hud.accent,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Types [text] in, character by character, with a cyan caret. The full
/// string is always laid out (and is the only `Text` in the tree), so layout
/// never jumps and `find.text` behaves like a plain `Text`.
class Typewriter extends StatefulWidget {
  const Typewriter(
    this.text, {
    super.key,
    this.style,
    this.caret,
    this.maxLines,
    this.charDelay = const Duration(milliseconds: 16),
    this.delay = const Duration(milliseconds: 220),
  });

  final String text;
  final TextStyle? style;
  final Color? caret;
  final int? maxLines;
  final Duration charDelay;
  final Duration delay;

  @override
  State<Typewriter> createState() => _TypewriterState();
}

class _TypewriterState extends State<Typewriter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration:
        widget.delay +
        Duration(
          microseconds: (widget.charDelay.inMicroseconds * widget.text.length)
              .clamp(0, 1100000),
        ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed) {
      if (AppMotion.reduced(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final total = _c.duration!.inMicroseconds;
    final lead = total == 0 ? 0.0 : widget.delay.inMicroseconds / total;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final done = _c.value >= 1;
        final p = ((_c.value - lead) / (1 - lead)).clamp(0.0, 1.0);
        final n = (widget.text.length * p).round();
        return Stack(
          children: [
            Opacity(
              opacity: done ? 1 : 0,
              child: Text(widget.text, style: style, maxLines: widget.maxLines),
            ),
            if (!done)
              Positioned.fill(
                child: RichText(
                  maxLines: widget.maxLines,
                  text: TextSpan(
                    style: style,
                    children: [
                      TextSpan(text: widget.text.substring(0, n)),
                      TextSpan(
                        text: '▍',
                        style: TextStyle(
                          color: widget.caret ?? context.hud.accent,
                        ),
                      ),
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

/// Full deterministic briefing: every summary sentence, what is still
/// missing, and "Ask JARVIS".
Future<void> showBriefingSheet(
  BuildContext context, {
  required DailySummary summary,
  required DateTime now,
}) {
  final router = GoRouter.maybeOf(context);
  return showHudBottomSheet<void>(
    context,
    title: 'Daily briefing',
    builder: (sheet) {
      final hud = sheet.hud;
      final t = Theme.of(sheet).textTheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${DateFormat('EEE d MMM').format(now).toUpperCase()} · '
            '${DateFormat('HH:mm').format(now)} · ON-DEVICE',
            style: hud.mono(size: 10, color: hud.accentInk),
          ),
          const SizedBox(height: AppSpacing.md),
          if (summary.lines.isEmpty)
            Text(
              'Nothing to summarise yet. Log food or water, or connect '
              'Health Connect, and the briefing fills itself in.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
          ...staggered([
            for (final line in summary.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlowIcon(
                      summaryIcon(line.topic),
                      size: 16,
                      color: summaryColor(line.topic),
                      framed: true,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(line.text, style: t.bodyMedium),
                      ),
                    ),
                  ],
                ),
              ),
          ]),
          if (summary.unavailable.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('NOT AVAILABLE YET', style: hud.label(size: 11)),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final u in summary.unavailable)
                  HudChip(label: u, icon: Icons.remove),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            'Built from your logged and synced data only.',
            style: t.labelSmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(
            label: 'Ask JARVIS',
            icon: Icons.auto_awesome,
            expand: true,
            onPressed: () {
              Navigator.of(sheet).pop();
              router?.go(
                '${AppPaths.coach}?prompt='
                '${Uri.encodeComponent(askJarvisPrompt)}',
              );
            },
          ),
        ],
      );
    },
  );
}
