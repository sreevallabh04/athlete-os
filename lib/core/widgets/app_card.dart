import 'package:flutter/material.dart';

import '../motion/entrance.dart';
import '../motion/pressable_scale.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// Base surface for dashboard content: a HUD glass slab with a luminous
/// hairline. Optionally tinted with an [accent] (light spills from the
/// top-left corner), framed with corner [brackets], given a bloom [glow],
/// and tappable (spring press + haptic).
///
/// Cards that mount while their page is appearing cascade in automatically
/// (see `EntranceScope`); set [animateEntrance] to false to opt out.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.accent,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.gradient,
    this.semanticLabel,
    this.onLongPress,
    this.brackets = false,
    this.glow = false,
    this.animateEntrance = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final EdgeInsetsGeometry padding;

  /// Replaces the glass fill (e.g. `AppGradients.subtle(color)` or a hero
  /// gradient).
  final Gradient? gradient;
  final String? semanticLabel;
  final VoidCallback? onLongPress;

  /// HUD corner brackets in the accent colour (hero / focus cards).
  final bool brackets;

  /// Soft bloom around the card in the accent colour.
  final bool glow;
  final bool animateEntrance;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _pressed = false;
  Duration? _delay;
  bool _claimed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_claimed) {
      _claimed = true;
      if (widget.animateEntrance) {
        _delay = EntranceScope.maybeOf(context)?.claim();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final accent = widget.accent;
    Widget surface = CustomPaint(
      painter: GlassPainter(
        hud: hud,
        radius: AppRadii.lg,
        accent: accent,
        fill: widget.gradient,
        borderStrength: accent != null ? 1.3 : 1,
        pressed: _pressed,
      ),
      // Transparent Material so ink from inner ListTiles/InkWells paints
      // above the glass instead of underneath it.
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadii.card,
        clipBehavior: Clip.none,
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
    if (widget.brackets) {
      surface = HudFrame(
        color: (accent ?? hud.accent).withValues(alpha: 0.85),
        inset: -3,
        cornerLength: 12,
        child: surface,
      );
    }
    if (widget.glow) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadii.card,
          boxShadow: AppGlows.soft(
            accent ?? hud.accent,
            strength: hud.glowStrength,
          ),
        ),
        child: surface,
      );
    }
    // Always wrapped (inert without callbacks) so a card that becomes
    // tappable later keeps its subtree state.
    surface = PressableScale(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      pressedScale: 0.975,
      onPressedChanged: (p) => setState(() => _pressed = p),
      child: surface,
    );
    surface = Semantics(
      label: widget.semanticLabel,
      button: widget.onTap != null,
      container: true,
      child: surface,
    );
    final delay = _delay;
    if (delay != null) {
      surface = Entrance(
        delay: delay,
        offset: const Offset(0, 16),
        fromScale: 0.985,
        child: surface,
      );
    }
    return surface;
  }
}

/// Section title with a HUD tick line and optional trailing action, used
/// between cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.action,
    this.onAction,
    this.subtitle,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  /// Colour of the leading marker (defaults to the theme accent).
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final c = accent ?? hud.accent;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
      // The title gets priority: it may take most of the row, and the
      // decorative tick line only fills what is left.
      // The title gets priority: it may take most of the space left after
      // the optional action, and the decorative tick line fills the rest.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 14,
            margin: const EdgeInsets.only(right: AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: c.withValues(alpha: 0.6 * hud.glowStrength),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.86),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(title, style: t.titleMedium),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: t.bodySmall?.copyWith(color: hud.textMuted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: ExcludeSemantics(
                      child: SizedBox(
                        height: 8,
                        child: CustomPaint(
                          painter: _TickLinePainter(hud.hairline),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: AppSpacing.xs),
            TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    );
  }
}

class _TickLinePainter extends CustomPainter {
  const _TickLinePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 8) return;
    final y = size.height / 2;
    final line = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0.0)],
      ).createShader(Offset.zero & size);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    final tick = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y - 3), Offset(0, y + 3), tick);
    for (var x = 6.0; x < size.width * 0.35; x += 6) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, y + 2.5),
        tick..color = color.withValues(alpha: 0.25 * (1 - x / size.width)),
      );
    }
  }

  @override
  bool shouldRepaint(_TickLinePainter old) => old.color != color;
}
