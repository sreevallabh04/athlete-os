import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// Header row used inside every Today deck card: glowing icon, a short HUD
/// label, optional trailing telemetry and a chevron when the card opens a
/// screen.
class DeckLabel extends StatelessWidget {
  const DeckLabel({
    super.key,
    required this.icon,
    required this.label,
    this.color,
    this.trailing,
    this.chevron = false,
  });

  final IconData icon;

  /// Pass UPPERCASE (≤ 3 words).
  final String label;
  final Color? color;
  final Widget? trailing;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.accent;
    return Row(
      children: [
        GlowIcon(icon, size: 15, color: c, glow: 0.7),
        const SizedBox(width: AppSpacing.sm),
        // Expanded (not Flexible + Spacer, which split the free space and
        // left trailing links floating mid-card).
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              label,
              style: hud.label(size: 11.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        ?trailing,
        if (chevron) ...[
          const SizedBox(width: 2),
          Icon(Icons.chevron_right, size: 18, color: hud.textMuted),
        ],
      ],
    );
  }
}

/// Small mono telemetry text for [DeckLabel.trailing].
class DeckTelemetry extends StatelessWidget {
  const DeckTelemetry(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Text(text, style: hud.mono(size: 10, color: color ?? hud.textMuted));
  }
}

/// A compact, honest inline "nothing here yet" line with an optional action
/// — replaces giant empty states on the deck.
class DeckHint extends StatelessWidget {
  const DeckHint({
    super.key,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.icon,
  });

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: hud.textMuted),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Text(
            text,
            style: t.bodyMedium?.copyWith(color: hud.textMuted),
          ),
        ),
        if (actionLabel != null) ...[
          const SizedBox(width: AppSpacing.sm),
          HudButton.secondary(
            label: actionLabel!,
            onPressed: onAction,
            compact: true,
          ),
        ],
      ],
    );
  }
}

/// Glowing status dot.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 6});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.8 * hud.glowStrength),
            blurRadius: size,
          ),
        ],
      ),
    );
  }
}

/// Text colour for metric/accent hues that must stay legible on the light
/// theme (metric colours are for strokes only there).
Color inkFor(BuildContext context, Color c) {
  final hud = context.hud;
  if (hud.isDark) return c;
  return Color.lerp(c, Colors.black, 0.45)!;
}

/// Gold text that stays AA on porcelain.
Color goldInk(BuildContext context) =>
    context.hud.isDark ? AppColors.gold : AppColors.goldInk;
