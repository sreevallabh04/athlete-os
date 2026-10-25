import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Animated circular progress ring. [progress] may exceed 1.0; the ring caps
/// visually but the caller's label can show the true value.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 120,
    this.stroke = 12,
    this.center,
    this.semanticLabel,
  });

  final double progress;
  final Color color;
  final double size;
  final double stroke;
  final Widget? center;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    final clamped = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    return Semantics(
      label: semanticLabel,
      value: '${(clamped * 100).round()} percent',
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: clamped),
          duration: AppDurations.slow,
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => CustomPaint(
            painter: _RingPainter(value, color, track, stroke),
            child: Center(child: child),
          ),
          child: center,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track, this.stroke);
  final double value;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final deflated = rect.deflate(stroke / 2);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(deflated, 0, math.pi * 2, false, base);
    if (value <= 0) return;
    final fg = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: [color.withValues(alpha: 0.65), color],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(deflated)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(deflated, -math.pi / 2, math.pi * 2 * value, false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// Labelled horizontal progress bar: "Protein   92 / 150 g".
class MetricBar extends StatelessWidget {
  const MetricBar({
    super.key,
    required this.label,
    required this.value,
    required this.target,
    required this.color,
    this.unit = '',
    this.formatter,
  });

  final String label;
  final double value;
  final double target;
  final Color color;
  final String unit;
  final String Function(double)? formatter;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final f = formatter ?? (double v) => v.round().toString();
    final p = target <= 0 ? 0.0 : (value / target).clamp(0.0, 1.0);
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
                      style: t.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: p),
              duration: AppDurations.slow,
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
