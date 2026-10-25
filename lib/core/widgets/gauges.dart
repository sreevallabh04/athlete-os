import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../motion/animated_ticker.dart';
import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';

/// Half-circle HUD gauge with tick scale, glowing sweep and a marker.
/// The centre shows [valueText] (ticker) and [label].
///
/// ```dart
/// ArcGauge(value: 0.72, valueText: '72', label: 'READINESS', color: AppColors.habit)
/// ```
class ArcGauge extends StatelessWidget {
  const ArcGauge({
    super.key,
    required this.value,
    this.valueText,
    this.label,
    this.color,
    this.width = 200,
    this.stroke = 10,
    this.semanticLabel,
  });

  /// 0..1
  final double value;
  final String? valueText;
  final String? label;
  final Color? color;
  final double width;
  final double stroke;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final v = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    final reduced = AppMotion.reduced(context);
    final h = width / 2 + stroke;
    return Semantics(
      label: semanticLabel ?? label,
      value: valueText ?? '${(v * 100).round()} percent',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: h,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: v),
          duration: reduced ? Duration.zero : AppDurations.data,
          curve: AppMotion.emphasizedDecelerate,
          builder: (context, t, child) => CustomPaint(
            painter: _ArcGaugePainter(
              value: t,
              color: c,
              stroke: stroke,
              hud: hud,
            ),
            child: child,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: stroke * 0.4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (valueText != null)
                    AnimatedTicker(
                      valueText!,
                      style: hud.number(size: width * 0.2),
                    ),
                  if (label != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(label!, style: hud.label(size: 11)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArcGaugePainter extends CustomPainter {
  _ArcGaugePainter({
    required this.value,
    required this.color,
    required this.stroke,
    required this.hud,
  });

  final double value;
  final Color color;
  final double stroke;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - stroke;
    final c = Offset(size.width / 2, size.height - stroke * 0.5);
    final rect = Rect.fromCircle(center: c, radius: r);
    const start = math.pi;
    const sweepAll = math.pi;

    // Tick scale outside the arc.
    final tick = Paint()
      ..strokeWidth = 1
      ..color = hud.text.withValues(alpha: hud.isDark ? 0.22 : 0.25);
    final lit = Paint()
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: 0.9);
    const n = 30;
    for (var i = 0; i <= n; i++) {
      final a = start + sweepAll * i / n;
      final dir = Offset(math.cos(a), math.sin(a));
      final major = i % 5 == 0;
      final r0 = r + stroke / 2 + 3;
      canvas.drawLine(
        c + dir * r0,
        c + dir * (r0 + (major ? 6 : 3)),
        i / n <= value ? lit : tick,
      );
    }

    // Track.
    canvas.drawArc(
      rect,
      start,
      sweepAll,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: hud.isDark ? 0.12 : 0.16),
    );
    if (value <= 0) return;
    final sweep = sweepAll * value;
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.5 * hud.glowStrength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.7),
    );
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.sweep(
          c,
          [color.withValues(alpha: 0.4), color],
          [0.5, 0.5 + 0.5 * math.max(0.001, value)],
          TileMode.clamp,
        ),
    );
    // Marker.
    final a = start + sweep;
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
      c + dir * (r - stroke * 0.9),
      c + dir * (r + stroke * 0.9),
      Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = Color.lerp(color, Colors.white, 0.7)!,
    );
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      old.value != value || old.color != color || old.hud != hud;
}

/// A glowing mini line chart for trends inside cards and tiles. Draws in
/// from left to right on first build; the last point pulses softly.
///
/// ```dart
/// HudSparkline(values: last7Days, color: AppColors.steps, height: 36)
/// ```
class HudSparkline extends StatelessWidget {
  const HudSparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 40,
    this.strokeWidth = 2,
    this.fill = true,
    this.showLastDot = true,
    this.semanticLabel,
  });

  final List<double> values;
  final Color? color;
  final double height;
  final double strokeWidth;
  final bool fill;
  final bool showLastDot;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: reduced ? Duration.zero : AppDurations.data,
          curve: AppMotion.emphasizedDecelerate,
          builder: (context, t, _) => CustomPaint(
            painter: HudSparklinePainter(
              values: values,
              color: c,
              strokeWidth: strokeWidth,
              fill: fill,
              showLastDot: showLastDot,
              progress: t,
              glow: hud.glowStrength,
            ),
          ),
        ),
      ),
    );
  }
}

class HudSparklinePainter extends CustomPainter {
  HudSparklinePainter({
    required this.values,
    required this.color,
    this.strokeWidth = 2,
    this.fill = true,
    this.showLastDot = true,
    this.progress = 1,
    this.glow = 1,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;
  final bool fill;
  final bool showLastDot;
  final double progress;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = values.where((v) => v.isFinite).toList();
    if (pts.length < 2) return;
    final lo = pts.reduce(math.min);
    final hi = pts.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final pad = strokeWidth * 2 + 2;
    final h = size.height - pad * 2;
    final offsets = [
      for (var i = 0; i < pts.length; i++)
        Offset(
          pad + (size.width - pad * 2) * i / (pts.length - 1),
          pad + h - (pts[i] - lo) / span * h,
        ),
    ];
    // Catmull-Rom → cubic Bézier for a smooth, honest curve.
    final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (var i = 0; i < offsets.length - 1; i++) {
      final p0 = offsets[math.max(0, i - 1)];
      final p1 = offsets[i];
      final p2 = offsets[i + 1];
      final p3 = offsets[math.min(offsets.length - 1, i + 2)];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    final clipW = size.width * progress;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, -10, clipW, size.height + 20));
    if (fill) {
      final area = Path.from(path)
        ..lineTo(offsets.last.dx, size.height)
        ..lineTo(offsets.first.dx, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0),
          ]),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.5
        ..color = color.withValues(alpha: 0.35 * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, strokeWidth * 2),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.restore();
    if (showLastDot && progress >= 0.98) {
      final p = offsets.last;
      canvas.drawCircle(
        p,
        strokeWidth * 3,
        Paint()
          ..color = color.withValues(alpha: 0.35 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, strokeWidth * 2),
      );
      canvas.drawCircle(
        p,
        strokeWidth * 1.4,
        Paint()..color = Color.lerp(color, Colors.white, 0.6)!,
      );
    }
  }

  @override
  bool shouldRepaint(HudSparklinePainter old) =>
      old.values != values ||
      old.color != color ||
      old.progress != progress ||
      old.fill != fill;
}
