import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../haptics/haptics.dart';
import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import 'celebration.dart';

/// Arc-reactor progress ring: an outer tick bezel, a segmented track, a
/// glowing sweep with a white-hot head and a thin inner ring.
///
/// [progress] may exceed 1.0; the ring caps visually but the caller's label
/// can show the true value. When progress crosses 1.0 while on screen the
/// ring pulses, bursts particles and fires the goal-reached haptic
/// (disable with [celebrate]).
class ProgressRing extends StatefulWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 120,
    this.stroke = 12,
    this.center,
    this.semanticLabel,
    this.celebrate = true,
    this.ticks = true,
  });

  final double progress;
  final Color color;
  final double size;
  final double stroke;
  final Widget? center;
  final String? semanticLabel;
  final bool celebrate;

  /// Outer tick bezel (auto-hidden below 56 px).
  final bool ticks;

  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing>
    with SingleTickerProviderStateMixin {
  // 0.00–0.37: waiting for the sweep to land; 0.37–1.00: bloom pulse.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..addListener(_onPulse);
  static const _land = 0.37;
  final _burst = CelebrationController();
  bool _fired = true;

  void _onPulse() {
    if (!_fired && _pulse.value >= _land) {
      _fired = true;
      _burst.fire();
      Haptics.goalReached();
    }
  }

  double get _pulseValue => _pulse.value < _land
      ? 0
      : math.sin((_pulse.value - _land) / (1 - _land) * math.pi);

  double get _clamped =>
      widget.progress.isFinite ? widget.progress.clamp(0.0, 1.0) : 0.0;

  @override
  void didUpdateWidget(ProgressRing old) {
    super.didUpdateWidget(old);
    final was = old.progress.isFinite ? old.progress : 0;
    final now = widget.progress.isFinite ? widget.progress : 0;
    if (widget.celebrate && was < 1 && now >= 1) {
      // Fire when the sweep lands, not when the data arrives.
      if (AppMotion.reduced(context)) {
        Haptics.success();
      } else {
        _fired = false;
        _pulse.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final reduced = AppMotion.reduced(context);
    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: _clamped),
      duration: reduced ? Duration.zero : AppDurations.data,
      curve: AppMotion.emphasizedDecelerate,
      builder: (context, value, child) => AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => CustomPaint(
          painter: ReactorRingPainter(
            value: value,
            color: widget.color,
            stroke: widget.stroke,
            hud: hud,
            ticks: widget.ticks && widget.size >= 56,
            pulse: _pulseValue,
          ),
          child: child,
        ),
        child: child,
      ),
      child: Center(child: widget.center),
    );
    return Semantics(
      label: widget.semanticLabel,
      value: '${(_clamped * 100).round()} percent',
      child: SizedBox.square(
        dimension: widget.size,
        child: CelebrationBurst(
          controller: _burst,
          color: widget.color,
          child: RepaintBoundary(child: ring),
        ),
      ),
    );
  }
}

class ReactorRingPainter extends CustomPainter {
  ReactorRingPainter({
    required this.value,
    required this.color,
    required this.stroke,
    required this.hud,
    this.ticks = true,
    this.pulse = 0,
  });

  final double value;
  final Color color;
  final double stroke;
  final HudTheme hud;
  final bool ticks;

  /// 0..1 extra bloom (goal-reached pulse).
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = math.min(size.width, size.height) / 2;
    final bezel = ticks ? math.max(4.0, stroke * 0.5) : 0.0;
    final r = outer - bezel - stroke / 2 - (ticks ? 2 : 0);
    final arcRect = Rect.fromCircle(center: c, radius: r);
    const start = -math.pi / 2;
    final g = hud.glowStrength;

    // Outer tick bezel: 60 ticks, lit up to the current progress.
    if (ticks) {
      const n = 60;
      final dim = Paint()
        ..color = hud.text.withValues(alpha: hud.isDark ? 0.14 : 0.18)
        ..strokeWidth = 1;
      final lit = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      for (var i = 0; i < n; i++) {
        final a = start + i * 2 * math.pi / n;
        final major = i % 5 == 0;
        final r1 = outer - 0.5;
        final r0 = r1 - (major ? bezel : bezel * 0.55);
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + dir * r0, c + dir * r1, i / n < value ? lit : dim);
      }
    }

    // Segmented track.
    const segments = 40;
    const gapRad = 0.035;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: hud.isDark ? 0.12 : 0.16);
    for (var i = 0; i < segments; i++) {
      final a0 = start + i * 2 * math.pi / segments + gapRad / 2;
      canvas.drawArc(
        arcRect,
        a0,
        2 * math.pi / segments - gapRad,
        false,
        track,
      );
    }

    // Inner hairline ring.
    canvas.drawCircle(
      c,
      r - stroke / 2 - 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.22),
    );

    if (value <= 0) return;
    final sweep = 2 * math.pi * value;

    // Bloom pass.
    canvas.drawArc(
      arcRect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * (1 + 0.6 * pulse)
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: (0.45 + 0.4 * pulse) * g)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.7),
    );

    // Main sweep (butt caps: a round start cap would sample the gradient's
    // bright end; the glowing head covers the leading edge).
    canvas.drawArc(
      arcRect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..shader = SweepGradient(
          colors: [color.withValues(alpha: 0.5), color],
          stops: [0, math.max(0.001, value)],
          transform: const GradientRotation(start),
        ).createShader(arcRect),
    );

    // Hot head.
    final head =
        c + Offset(math.cos(start + sweep), math.sin(start + sweep)) * r;
    canvas.drawCircle(
      head,
      stroke * 0.9,
      Paint()
        ..color = color.withValues(alpha: 0.5 * g)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.5),
    );
    canvas.drawCircle(
      head,
      stroke * 0.28,
      Paint()..color = Color.lerp(color, Colors.white, 0.75)!,
    );
  }

  @override
  bool shouldRepaint(ReactorRingPainter old) =>
      old.value != value ||
      old.color != color ||
      old.stroke != stroke ||
      old.hud != hud ||
      old.ticks != ticks ||
      old.pulse != pulse;
}

/// Labelled horizontal progress bar: "Protein   92 / 150 g", rendered as a
/// luminous segmented HUD bar with a glowing leading edge.
class MetricBar extends StatelessWidget {
  const MetricBar({
    super.key,
    required this.label,
    required this.value,
    required this.target,
    required this.color,
    this.unit = '',
    this.formatter,
    this.segments = 24,
  });

  final String label;
  final double value;
  final double target;
  final Color color;
  final String unit;
  final String Function(double)? formatter;

  /// Number of bar segments (0 = continuous).
  final int segments;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final f = formatter ?? (double v) => v.round().toString();
    final p = target <= 0 ? 0.0 : (value / target).clamp(0.0, 1.0);
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label: '$label ${f(value)} of ${f(target)} $unit',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: t.labelLarge)),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: f(value), style: t.labelLarge),
                    TextSpan(
                      text: ' / ${f(target)}$unit',
                      style: t.labelMedium?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs + 3),
          SizedBox(
            height: 8,
            width: double.infinity,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: p),
              duration: reduced ? Duration.zero : AppDurations.data,
              curve: AppMotion.emphasizedDecelerate,
              builder: (_, v, _) => CustomPaint(
                painter: SegmentedBarPainter(
                  value: v,
                  color: color,
                  hud: hud,
                  segments: segments,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SegmentedBarPainter extends CustomPainter {
  SegmentedBarPainter({
    required this.value,
    required this.color,
    required this.hud,
    this.segments = 24,
  });

  final double value;
  final Color color;
  final HudTheme hud;
  final int segments;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final radius = Radius.circular(math.min(2.5, h / 2));
    final trackPaint = Paint()
      ..color = color.withValues(alpha: hud.isDark ? 0.12 : 0.16);
    final fillW = size.width * value;
    if (segments <= 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, radius),
        trackPaint,
      );
    }
    // Bloom under the filled portion.
    if (fillW > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, fillW, h), radius),
        Paint()
          ..color = color.withValues(alpha: 0.35 * hud.glowStrength)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.8),
      );
    }
    final fill = Paint()
      ..shader = LinearGradient(colors: [color.withValues(alpha: 0.55), color])
          .createShader(Rect.fromLTWH(0, 0, math.max(1, fillW), h));
    if (segments <= 0) {
      if (fillW > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, fillW, h), radius),
          fill,
        );
      }
    } else {
      const gap = 2.0;
      final segW = (size.width - gap * (segments - 1)) / segments;
      for (var i = 0; i < segments; i++) {
        final x = i * (segW + gap);
        final rect = Rect.fromLTWH(x, 0, segW, h);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), trackPaint);
        if (fillW > x) {
          final w = math.min(segW, fillW - x);
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w, h), radius),
            fill,
          );
        }
      }
    }
    // Leading edge spark.
    if (value > 0.01 && value < 0.999) {
      canvas.drawRect(
        Rect.fromLTWH(fillW - 1.5, -1, 1.5, h + 2),
        Paint()..color = Color.lerp(color, Colors.white, 0.7)!,
      );
    }
  }

  @override
  bool shouldRepaint(SegmentedBarPainter old) =>
      old.value != value ||
      old.color != color ||
      old.hud != hud ||
      old.segments != segments;
}
