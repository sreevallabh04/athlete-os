import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';

/// Compact HUD activity indicator: two counter-rotating segmented arcs and
/// a breathing core. Replaces `CircularProgressIndicator`.
class HudSpinner extends StatefulWidget {
  const HudSpinner({super.key, this.size = 36, this.color, this.semanticLabel});

  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  State<HudSpinner> createState() => _HudSpinnerState();
}

class _HudSpinnerState extends State<HudSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.value = 0.15;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? HudTheme.of(context).accent;
    return Semantics(
      label: widget.semanticLabel ?? 'Loading',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) =>
                CustomPaint(painter: _SpinnerPainter(_c.value, color)),
          ),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final a = t * 2 * math.pi;
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, r * 0.12)
      ..strokeCap = StrokeCap.round
      ..color = color;
    final rect = Rect.fromCircle(center: c, radius: r * 0.86);
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(rect, a * 2 + i * 2 * math.pi / 3, 0.9, false, outer);
    }
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, r * 0.06)
      ..color = color.withValues(alpha: 0.5);
    final rect2 = Rect.fromCircle(center: c, radius: r * 0.56);
    for (var i = 0; i < 6; i++) {
      canvas.drawArc(rect2, -a * 3 + i * math.pi / 3, 0.6, false, inner);
    }
    final breathe = 0.5 + 0.5 * math.sin(a * 4);
    canvas.drawCircle(
      c,
      r * (0.14 + 0.05 * breathe),
      Paint()
        ..color = color.withValues(alpha: 0.6 + 0.4 * breathe)
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, r * 0.12),
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.t != t || old.color != color;
}

/// Skeleton placeholder with a HUD scan line sweeping over glass bars,
/// instead of a generic shimmer. Size it like the content it stands in for.
///
/// ```dart
/// const ScanlineLoader(lines: 3)            // text block
/// const ScanlineLoader(height: 140, lines: 0) // chart / image block
/// ```
class ScanlineLoader extends StatefulWidget {
  const ScanlineLoader({
    super.key,
    this.height,
    this.lines = 3,
    this.color,
    this.radius = AppRadii.md,
  });

  /// Fixed height for a block skeleton; null sizes to [lines].
  final double? height;

  /// Number of text bars (0 = one solid block).
  final int lines;
  final Color? color;
  final double radius;

  @override
  State<ScanlineLoader> createState() => _ScanlineLoaderState();
}

class _ScanlineLoaderState extends State<ScanlineLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final color = widget.color ?? hud.accent;
    final h = widget.height ?? (widget.lines <= 0 ? 64.0 : widget.lines * 22.0);
    return Semantics(
      label: 'Loading',
      child: RepaintBoundary(
        child: SizedBox(
          height: h,
          width: double.infinity,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _ScanPainter(
                t: _c.value,
                color: color,
                hud: hud,
                lines: widget.lines,
                radius: widget.radius,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanPainter extends CustomPainter {
  _ScanPainter({
    required this.t,
    required this.color,
    required this.hud,
    required this.lines,
    required this.radius,
  });

  final double t;
  final Color color;
  final HudTheme hud;
  final int lines;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final barPaint = Paint()
      ..color = hud.text.withValues(alpha: hud.isDark ? 0.06 : 0.07);
    final bars = <RRect>[];
    if (lines <= 0) {
      bars.add(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    } else {
      final rowH = size.height / lines;
      const widths = [0.92, 0.74, 0.86, 0.58, 0.8];
      for (var i = 0; i < lines; i++) {
        final w =
            size.width * (i == lines - 1 ? 0.52 : widths[i % widths.length]);
        bars.add(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, i * rowH + rowH * 0.2, w, rowH * 0.6),
            const Radius.circular(4),
          ),
        );
      }
    }
    for (final b in bars) {
      canvas.drawRRect(b, barPaint);
    }
    // Scan line sweeping left → right with a trailing glow.
    final x =
        -size.width * 0.2 +
        size.width * 1.4 * Curves.easeInOutSine.transform(t);
    final trail = Rect.fromLTWH(x - 90, 0, 90, size.height);
    canvas.save();
    final clip = Path();
    for (final b in bars) {
      clip.addRRect(b);
    }
    canvas.clipPath(clip);
    canvas.drawRect(
      trail,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.16)],
        ).createShader(trail),
    );
    canvas.restore();
    canvas.drawRect(
      Rect.fromLTWH(x, 0, 1.5, size.height),
      Paint()..color = color.withValues(alpha: 0.75),
    );
    canvas.drawRect(
      Rect.fromLTWH(x - 2, 0, 5, size.height),
      Paint()
        ..color = color.withValues(alpha: 0.3 * hud.glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  @override
  bool shouldRepaint(_ScanPainter old) =>
      old.t != t || old.color != color || old.lines != lines;
}
