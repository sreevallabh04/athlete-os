import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// Paints a HUD glass slab: gradient fill, optional accent "light source"
/// in the top-left corner, an inner top highlight and a luminous gradient
/// hairline. One painter, no saveLayer, no backdrop blur.
class GlassPainter extends CustomPainter {
  const GlassPainter({
    required this.hud,
    required this.radius,
    this.accent,
    this.fill,
    this.borderStrength = 1,
    this.pressed = false,
  });

  final HudTheme hud;
  final double radius;
  final Color? accent;

  /// Overrides the default glass gradient.
  final Gradient? fill;
  final double borderStrength;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final dark = hud.isDark;
    final a = accent;

    // Fill.
    final Gradient g =
        fill ??
        LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  Color.alphaBlend(
                    (a ?? Colors.white).withValues(
                      alpha: a == null ? 0.05 : 0.055,
                    ),
                    const Color(0xB3151417),
                  ),
                  const Color(0x99100F12),
                ]
              : [
                  Colors.white.withValues(alpha: 0.92),
                  Colors.white.withValues(alpha: 0.78),
                ],
        );
    canvas.drawRRect(rr, Paint()..shader = g.createShader(rect));

    // Accent light spilling from the top-left corner.
    if (a != null) {
      final r = math.max(size.width, size.height) * 0.9;
      canvas.save();
      canvas.clipRRect(rr);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, r, [
            a.withValues(alpha: dark ? 0.08 : 0.06),
            a.withValues(alpha: 0),
          ]),
      );
      canvas.restore();
    }

    // Inner top highlight (glass edge catching light).
    final hl = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = ui.Gradient.linear(
        Offset(rect.left + radius, 0),
        Offset(rect.right - radius, 0),
        [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: dark ? 0.10 : 0.6),
          Colors.white.withValues(alpha: 0),
        ],
        const [0, 0.5, 1],
      );
    canvas.drawLine(
      Offset(rect.left + radius * 0.6, 1.5),
      Offset(rect.right - radius * 0.6, 1.5),
      hl,
    );

    // Luminous hairline.
    // Accent hairlines are tempered toward the warm neutral hairline so a
    // saturated accent (Stark red) frames a card without flooding it.
    final base = a == null ? hud.hairline : Color.lerp(a, hud.hairline, 0.3)!;
    final strength = borderStrength * (pressed ? 1.8 : 1) * (dark ? 1 : 0.9);
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = AppGradients.hairline(
          base,
          strength: strength,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(GlassPainter old) =>
      old.hud != hud ||
      old.radius != radius ||
      old.accent != accent ||
      old.fill != fill ||
      old.borderStrength != borderStrength ||
      old.pressed != pressed;
}

/// A HUD glass container. Use for any grouped surface that isn't a tappable
/// card (sheets, overlays, toolbars). Set [blur] > 0 only for chrome that
/// floats over moving content (dock, headers): backdrop blur re-renders
/// every frame the background animates.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.radius = AppRadii.lg,
    this.blur = 0,
    this.accent,
    this.fill,
    this.borderStrength = 1,
    this.glow = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final Color? accent;
  final Gradient? fill;
  final double borderStrength;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    Widget w = CustomPaint(
      painter: GlassPainter(
        hud: hud,
        radius: radius,
        accent: accent,
        fill: fill,
        borderStrength: borderStrength,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (blur > 0) {
      w = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: w,
        ),
      );
    }
    if (glow) {
      w = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: AppGlows.soft(
            accent ?? hud.accent,
            strength: hud.glowStrength,
          ),
        ),
        child: w,
      );
    }
    return w;
  }
}

/// Corner-bracket HUD frame drawn around [child]. Optional edge ticks and a
/// small mono tag (e.g. `SYS·01`) in the top-left.
class HudFrame extends StatelessWidget {
  const HudFrame({
    super.key,
    required this.child,
    this.color,
    this.cornerLength = 14,
    this.strokeWidth = 1.5,
    this.inset = 0,
    this.ticks = false,
    this.tag,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final Color? color;
  final double cornerLength;
  final double strokeWidth;

  /// Brackets sit this far *outside* (negative) or inside (positive) the box.
  final double inset;
  final bool ticks;
  final String? tag;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final frame = CustomPaint(
      foregroundPainter: HudFramePainter(
        color: c,
        cornerLength: cornerLength,
        strokeWidth: strokeWidth,
        inset: inset,
        ticks: ticks,
        tag: tag,
        tagStyle: AppTypography.mono(c.withValues(alpha: 0.8), size: 9),
      ),
      child: Padding(padding: padding, child: child),
    );
    // The tag straddles the top edge: reserve room so it never touches
    // whatever sits above the frame.
    if (tag == null) return frame;
    return Padding(
      padding: EdgeInsets.only(top: 8 + (inset < 0 ? -inset : 0)),
      child: frame,
    );
  }
}

class HudFramePainter extends CustomPainter {
  const HudFramePainter({
    required this.color,
    this.cornerLength = 14,
    this.strokeWidth = 1.5,
    this.inset = 0,
    this.ticks = false,
    this.tag,
    this.tagStyle,
    this.progress = 1,
  });

  final Color color;
  final double cornerLength;
  final double strokeWidth;
  final double inset;
  final bool ticks;
  final String? tag;
  final TextStyle? tagStyle;

  /// 0..1 draw-in (brackets grow from their corners).
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(inset);
    final l = cornerLength * progress.clamp(0, 1);
    if (l <= 0) return;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square;
    final path = Path()
      ..moveTo(r.left, r.top + l)
      ..lineTo(r.left, r.top)
      ..lineTo(r.left + l, r.top)
      ..moveTo(r.right - l, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, r.top + l)
      ..moveTo(r.right, r.bottom - l)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.right - l, r.bottom)
      ..moveTo(r.left + l, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..lineTo(r.left, r.bottom - l);
    canvas.drawPath(path, p);
    if (ticks) {
      final t = Paint()
        ..color = color.withValues(alpha: color.a * 0.45)
        ..strokeWidth = 1;
      const n = 12;
      for (var i = tag == null ? 1 : 4; i < n; i++) {
        if (i == n ~/ 2) continue;
        final x = r.left + r.width * i / n;
        canvas.drawLine(Offset(x, r.top), Offset(x, r.top + 3), t);
        canvas.drawLine(Offset(x, r.bottom), Offset(x, r.bottom - 3), t);
      }
    }
    if (tag != null && tagStyle != null) {
      final tp = TextPainter(
        text: TextSpan(text: tag, style: tagStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(r.left + l + 6, r.top - tp.height / 2));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(HudFramePainter old) =>
      old.color != color ||
      old.cornerLength != cornerLength ||
      old.strokeWidth != strokeWidth ||
      old.inset != inset ||
      old.ticks != ticks ||
      old.tag != tag ||
      old.progress != progress;
}
