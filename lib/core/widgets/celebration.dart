import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../haptics/haptics.dart';
import '../motion/motion_tokens.dart';
import '../theme/tokens.dart';

/// Imperative trigger for [CelebrationBurst].
class CelebrationController extends ChangeNotifier {
  int _shots = 0;
  int get shots => _shots;

  /// Plays the burst once (restarts if already playing).
  void fire() {
    _shots++;
    notifyListeners();
  }
}

/// A tasteful goal-reached moment painted *over* [child] (never clipped):
/// a shockwave ring, a radial spray of accent/gold sparks and a soft flash.
/// ~1.1 s, no layout impact, ignores pointers.
///
/// ```dart
/// final burst = CelebrationController();
/// CelebrationBurst(controller: burst, child: ring);
/// burst.fire(); // e.g. when a goal completes
/// ```
class CelebrationBurst extends StatefulWidget {
  const CelebrationBurst({
    super.key,
    required this.child,
    required this.controller,
    this.color = AppColors.cyan,
    this.particles = 26,
    this.haptic = false,
    this.spread = 1.0,
  });

  final Widget child;
  final CelebrationController controller;
  final Color color;
  final int particles;

  /// Fire `Haptics.goalReached` with the burst (off by default because
  /// `ProgressRing` already does).
  final bool haptic;

  /// Burst radius as a multiple of the child's half-size.
  final double spread;

  @override
  State<CelebrationBurst> createState() => _CelebrationBurstState();
}

class _CelebrationBurstState extends State<CelebrationBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  int _seed = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_fire);
  }

  @override
  void didUpdateWidget(CelebrationBurst old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_fire);
      widget.controller.addListener(_fire);
    }
  }

  void _fire() {
    if (widget.haptic) Haptics.goalReached();
    if (AppMotion.reduced(context)) return;
    setState(() => _seed = widget.controller.shots);
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_fire);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    fit: StackFit.passthrough,
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => _c.isAnimating
                ? CustomPaint(
                    painter: _BurstPainter(
                      t: _c.value,
                      color: widget.color,
                      count: widget.particles,
                      seed: _seed,
                      spread: widget.spread,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ],
  );
}

class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.t,
    required this.color,
    required this.count,
    required this.seed,
    required this.spread,
  });

  final double t;
  final Color color;
  final int count;
  final int seed;
  final double spread;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = math.min(size.width, size.height) / 2 * spread;
    final rnd = math.Random(seed * 7919 + 17);
    final ease = Curves.easeOutCubic.transform(t);

    // Flash.
    final flash = (1 - t * 3).clamp(0.0, 1.0);
    if (flash > 0) {
      canvas.drawCircle(
        c,
        base * 0.9,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.35 * flash),
              color.withValues(alpha: 0.18 * flash),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: base * 0.9)),
      );
    }

    // Shockwave rings.
    for (final (delay, width) in const [(0.0, 2.5), (0.12, 1.2)]) {
      final lt = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (lt <= 0 || lt >= 1) continue;
      final e = Curves.easeOutCubic.transform(lt);
      canvas.drawCircle(
        c,
        base * (0.75 + 0.75 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * (1 - e) + 0.5
          ..color = color.withValues(alpha: 0.8 * (1 - e)),
      );
    }

    // Sparks.
    for (var i = 0; i < count; i++) {
      final a = (i / count) * 2 * math.pi + rnd.nextDouble() * 0.4;
      final speed = 0.55 + rnd.nextDouble() * 0.75;
      final gold = i % 4 == 0;
      final white = i % 7 == 0;
      final col = white
          ? Colors.white
          : gold
          ? AppColors.gold
          : color;
      final dir = Offset(math.cos(a), math.sin(a));
      final r0 = base * 0.78;
      final dist = r0 + base * 0.85 * speed * ease;
      final fade = (1 - t).clamp(0.0, 1.0);
      final len = base * 0.16 * speed * (1 - ease) + 1.5;
      final p1 = c + dir * dist;
      final p0 = c + dir * (dist - len);
      canvas.drawLine(
        p0,
        p1,
        Paint()
          ..color = col.withValues(alpha: 0.9 * fade)
          ..strokeWidth = (gold ? 2.2 : 1.6) * (1 - 0.5 * ease)
          ..strokeCap = StrokeCap.round,
      );
      if (i % 3 == 0) {
        canvas.drawCircle(
          p1,
          2.6 * fade,
          Paint()
            ..color = col.withValues(alpha: 0.45 * fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t || old.seed != seed;
}
