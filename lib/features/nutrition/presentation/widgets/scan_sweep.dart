import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/widgets/widgets.dart';

/// A glowing scan line that sweeps up and down its box with a fading
/// trail. Ignores pointers. Reduced motion parks it in the middle.
class ScanSweep extends StatefulWidget {
  const ScanSweep({
    super.key,
    this.color,
    this.period = const Duration(milliseconds: 2200),
    this.active = true,
  });

  final Color? color;
  final Duration period;
  final bool active;

  @override
  State<ScanSweep> createState() => _ScanSweepState();
}

class _ScanSweepState extends State<ScanSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ScanSweep old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (!widget.active || AppMotion.reduced(context)) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      unawaited(_c.repeat(reverse: true));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.hud.accent;
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _SweepPainter(
              t: Curves.easeInOutSine.transform(_c.value),
              down: _c.status != AnimationStatus.reverse,
              color: color,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.t, required this.down, required this.color});
  final double t;
  final bool down;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * t;
    const trail = 46.0;
    final rect = down
        ? Rect.fromLTRB(0, y - trail, size.width, y)
        : Rect.fromLTRB(0, y, size.width, y + trail);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: down ? Alignment.topCenter : Alignment.bottomCenter,
          end: down ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.22)],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 6
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 1.6
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            Color.lerp(color, Colors.white, 0.5)!,
            color.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.t != t || old.down != down || old.color != color;
}
