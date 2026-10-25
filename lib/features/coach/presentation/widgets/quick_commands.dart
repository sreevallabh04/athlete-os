import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../agent/briefing.dart';

/// What a quick command does when tapped.
enum QuickAction { brief, review, prompt }

class QuickCommand {
  const QuickCommand(
    this.label,
    this.icon, {
    this.prompt,
    this.action = QuickAction.prompt,
  });

  final String label;
  final IconData icon;

  /// Text sent to the coach (defaults to [label]).
  final String? prompt;
  final QuickAction action;

  String get text => prompt ?? label;
}

/// Facts the suggestions depend on. Unknown = false/0, so a suggestion
/// only appears when the data behind it exists.
class QuickContext {
  const QuickContext({
    required this.now,
    this.hasNutritionTarget = false,
    this.hasCompetition = false,
    this.hasSessionToday = false,
    this.pendingDrafts = 0,
    this.stepsBelowGoal = false,
    this.waterBelowGoal = false,
  });

  final DateTime now;
  final bool hasNutritionTarget;
  final bool hasCompetition;
  final bool hasSessionToday;
  final int pendingDrafts;
  final bool stepsBelowGoal;
  final bool waterBelowGoal;
}

/// Deterministic, context-aware suggestions (max [max]). Pure; unit-tested.
List<QuickCommand> quickCommands(QuickContext c, {int max = 7}) {
  final h = c.now.hour;
  final morning = h >= 4 && h < 12;
  final evening = h >= 17 || h < 4;
  final out = <QuickCommand>[
    if (briefingModeFor(c.now) == BriefingMode.morning)
      const QuickCommand(
        'Brief me',
        Icons.wb_twilight_rounded,
        action: QuickAction.brief,
      )
    else
      const QuickCommand(
        'Review my day',
        Icons.nights_stay_outlined,
        action: QuickAction.review,
      ),
    if (c.hasSessionToday && !evening)
      const QuickCommand(
        "What's my session today?",
        Icons.fitness_center_rounded,
      ),
    if (c.hasNutritionTarget)
      const QuickCommand(
        'How much protein left?',
        Icons.egg_alt_outlined,
        prompt: 'How much protein do I have left today?',
      ),
    if (c.stepsBelowGoal)
      const QuickCommand('How many steps left?', Icons.directions_walk_rounded),
    if (morning)
      const QuickCommand(
        'Find a workout slot',
        Icons.event_available_outlined,
        prompt: 'Plan a 45-min workout slot today',
      ),
    if (c.waterBelowGoal && !morning)
      const QuickCommand(
        'Log 500 ml water',
        Icons.water_drop_outlined,
        prompt: 'I drank 500 ml of water',
      ),
    if (c.pendingDrafts > 0)
      QuickCommand(
        c.pendingDrafts == 1
            ? '1 reply awaiting approval'
            : '${c.pendingDrafts} replies awaiting approval',
        Icons.mark_chat_unread_outlined,
        prompt: 'Which messages need my reply?',
      ),
    if (c.hasCompetition)
      const QuickCommand(
        'Competition countdown',
        Icons.emoji_events_outlined,
        prompt: 'Days until my competition?',
      ),
    if (evening && c.hasNutritionTarget)
      const QuickCommand(
        'What should I eat tonight?',
        Icons.restaurant_rounded,
        prompt: 'What can I eat tonight to hit my targets?',
      ),
    const QuickCommand(
      'How did my last workout compare?',
      Icons.insights_rounded,
    ),
    const QuickCommand(
      'Weekly report',
      Icons.query_stats_rounded,
      prompt: 'How did this week go?',
    ),
  ];
  return out.take(max).toList();
}

/// Maps a spoken phrase to a briefing command (voice shortcuts).
QuickAction? matchVoiceCommand(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (RegExp(
    r'^(jarvis )?(brief me|morning briefing|give me (my|the) briefing)$',
  ).hasMatch(t)) {
    return QuickAction.brief;
  }
  if (RegExp(
    r'^(jarvis )?(review my day|evening review|how did (my|the) day go)$',
  ).hasMatch(t)) {
    return QuickAction.review;
  }
  return null;
}

/// Horizontal, snapping carousel of [QuickCommand] pills. The first one is
/// highlighted (the time-of-day command).
class QuickCommandBar extends StatelessWidget {
  const QuickCommandBar({
    super.key,
    required this.commands,
    required this.onSelected,
    this.enabled = true,
  });

  final List<QuickCommand> commands;
  final ValueChanged<QuickCommand> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: scaler.scale(36) + 12,
      child: ShaderMask(
        shaderCallback: (r) => const LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, 0.04, 0.92, 1],
        ).createShader(r),
        blendMode: BlendMode.dstIn,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.gutter,
            vertical: 6,
          ),
          itemCount: commands.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, i) => Entrance(
            delay: Duration(milliseconds: 60 + 40 * i.clamp(0, 6)),
            offset: const Offset(18, 0),
            child: _CommandPill(
              command: commands[i],
              primary: i == 0,
              onTap: enabled ? () => onSelected(commands[i]) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandPill extends StatelessWidget {
  const _CommandPill({
    required this.command,
    required this.primary,
    required this.onTap,
  });

  final QuickCommand command;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final c = hud.accent;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: primary
              ? [c.withValues(alpha: 0.22), c.withValues(alpha: 0.08)]
              : [
                  hud.text.withValues(alpha: hud.isDark ? 0.07 : 0.06),
                  hud.text.withValues(alpha: hud.isDark ? 0.03 : 0.03),
                ],
        ),
        border: Border.all(
          color: primary
              ? c.withValues(alpha: 0.7)
              : hud.hairline.withValues(alpha: hud.isDark ? 0.18 : 0.3),
        ),
        boxShadow: primary
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.28 * hud.glowStrength),
                  blurRadius: 14,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(command.icon, size: 16, color: primary ? c : hud.textMuted),
          const SizedBox(width: 7),
          Text(
            command.label,
            style: t.labelLarge?.copyWith(
              color: primary ? hud.text : hud.text.withValues(alpha: 0.86),
              fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: command.label,
      excludeSemantics: true,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: PressableScale(
          onTap: onTap,
          haptic: PressHaptic.selection,
          pressedScale: 0.94,
          child: pill,
        ),
      ),
    );
  }
}
