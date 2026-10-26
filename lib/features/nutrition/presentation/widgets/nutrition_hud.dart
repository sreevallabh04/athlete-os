import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/repositories/settings_repository.dart';

/// Warm red used for "over target" states (calories, macros). Softer than
/// the alert red so going over reads as information, not an error.
const Color overColor = AppColors.over;

// ---------------------------------------------------------------------------
// Once-per-day goal celebrations
// ---------------------------------------------------------------------------

/// Records which goals were already celebrated today (AppSettings), so a
/// goal never celebrates twice on the same day, across screens and restarts.
abstract final class GoalCelebrations {
  static final Set<String> _inflight = {};

  static String _key(String goal) => 'nutrition.celebrated.$goal';

  /// True (and recorded) when [goal] has not been celebrated on [date] yet.
  static Future<bool> claim(
    SettingsRepository settings,
    String goal,
    String date,
  ) async {
    final id = '$goal@$date';
    if (!_inflight.add(id)) return false;
    try {
      final last = await settings.get<String>(_key(goal));
      if (last == date) return false;
      await settings.set(_key(goal), date);
      return true;
    } catch (_) {
      return false;
    } finally {
      _inflight.remove(id);
    }
  }
}

/// A goal-reached moment that waits until its screen is actually visible.
///
/// Screens [arm] it when a value crosses its target (detected from data
/// streams) and call [maybeFire] from `build`: it fires only while the
/// subtree's tickers are enabled (i.e. the route is on stage), claims the
/// once-per-day slot, then plays [burst] with the goal-reached haptic.
class GoalPulse {
  GoalPulse(this.goal, {this.onFired});

  final String goal;
  final VoidCallback? onFired;
  final CelebrationController burst = CelebrationController();
  String? _pendingDate;
  bool _disposed = false;
  Timer? _timer;

  void arm(String date) => _pendingDate = date;

  /// Fires a pending celebration when [visible] and the route is on stage.
  /// Waits a beat so it lands after any route transition settles.
  void maybeFire(
    BuildContext context,
    SettingsRepository settings, {
    bool visible = true,
  }) {
    final date = _pendingDate;
    if (date == null || !visible || !TickerMode.valuesOf(context).enabled) {
      return;
    }
    _pendingDate = null;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 420), () async {
      final ok = await GoalCelebrations.claim(settings, goal, date);
      if (!ok || _disposed) return;
      burst.fire();
      Haptics.goalReached();
      onFired?.call();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    burst.dispose();
  }
}

// ---------------------------------------------------------------------------
// Macro reactor (Nutrition hero)
// ---------------------------------------------------------------------------

@immutable
class ReactorValues {
  const ReactorValues({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  static const zero = ReactorValues(calories: 0, protein: 0, carbs: 0, fat: 0);

  /// Unclamped consumed / target ratios (1.2 = 20 % over).
  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  ReactorValues lerp(ReactorValues o, double t) => ReactorValues(
    calories: calories + (o.calories - calories) * t,
    protein: protein + (o.protein - protein) * t,
    carbs: carbs + (o.carbs - carbs) * t,
    fat: fat + (o.fat - fat) * t,
  );

  @override
  bool operator ==(Object other) =>
      other is ReactorValues &&
      other.calories == calories &&
      other.protein == protein &&
      other.carbs == carbs &&
      other.fat == fat;

  @override
  int get hashCode => Object.hash(calories, protein, carbs, fat);
}

class _ReactorTween extends Tween<ReactorValues> {
  _ReactorTween({required ReactorValues begin, required ReactorValues end})
    : super(begin: begin, end: end);

  @override
  ReactorValues lerp(double t) => begin!.lerp(end!, t);
}

/// The Nutrition hero: a central calorie reactor ring with protein, carbs
/// and fat orbiting it as three arcs. Over-target portions glow warm red.
/// Values sweep in on change; a faint bezel drifts while on screen.
class MacroReactor extends StatefulWidget {
  const MacroReactor({
    super.key,
    required this.values,
    required this.center,
    this.size = 260,
    this.semanticLabel,
  });

  final ReactorValues values;
  final Widget center;
  final double size;
  final String? semanticLabel;

  @override
  State<MacroReactor> createState() => _MacroReactorState();
}

class _MacroReactorState extends State<MacroReactor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 48),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      unawaited(_spin.repeat());
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label: widget.semanticLabel,
      container: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: RepaintBoundary(
          child: TweenAnimationBuilder<ReactorValues>(
            tween: _ReactorTween(begin: ReactorValues.zero, end: widget.values),
            duration: reduced ? Duration.zero : AppMotion.data,
            curve: AppMotion.emphasizedDecelerate,
            builder: (context, v, child) => AnimatedBuilder(
              animation: _spin,
              builder: (context, child) => CustomPaint(
                painter: _MacroReactorPainter(
                  v: v,
                  spin: _spin.value,
                  hud: hud,
                  labelStyle: hud.label(size: 10.5),
                ),
                child: child,
              ),
              child: child,
            ),
            child: Center(child: widget.center),
          ),
        ),
      ),
    );
  }
}

class _MacroReactorPainter extends CustomPainter {
  _MacroReactorPainter({
    required this.v,
    required this.spin,
    required this.hud,
    required this.labelStyle,
  });

  final ReactorValues v;
  final double spin;
  final HudTheme hud;
  final TextStyle labelStyle;

  static const _gapDeg = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final glow = hud.glowStrength;

    // ── Drifting bezel ticks ────────────────────────────────────────────
    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..color = hud.hairline.withValues(alpha: hud.isDark ? 0.22 : 0.3);
    const n = 96;
    for (var i = 0; i < n; i++) {
      final a = (i / n + spin) * 2 * math.pi;
      final long = i % 8 == 0;
      tick.strokeWidth = long ? 1.4 : 0.8;
      final r1 = r - 1;
      final r2 = r - (long ? 7 : 4);
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r1,
        c + Offset(math.cos(a), math.sin(a)) * r2,
        tick,
      );
    }

    // ── Macro orbit (three sectors) ─────────────────────────────────────
    final orbitR = r - 18;
    const orbitW = 7.0;
    final sweepDeg = (360 - 3 * _gapDeg) / 3;
    final macros = [
      ('P', v.protein, AppColors.protein),
      ('C', v.carbs, AppColors.carbs),
      ('F', v.fat, AppColors.fat),
    ];
    final orbitRect = Rect.fromCircle(center: c, radius: orbitR);
    for (var i = 0; i < 3; i++) {
      final (letter, p, color) = macros[i];
      final startDeg = -90 + _gapDeg / 2 + i * (sweepDeg + _gapDeg);
      final start = _rad(startDeg);
      final sweep = _rad(sweepDeg);
      // Track.
      canvas.drawArc(
        orbitRect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = orbitW
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: hud.isDark ? 0.12 : 0.16),
      );
      final fill = p.isFinite ? p.clamp(0.0, 1.0) : 0.0;
      if (fill > 0.002) {
        _glowArc(canvas, orbitRect, start, sweep * fill, color, orbitW, glow);
      }
      if (p > 1) {
        final over = (p - 1).clamp(0.0, 1.0);
        _glowArc(
          canvas,
          orbitRect,
          start + sweep * (1 - over),
          sweep * over,
          overColor,
          orbitW,
          glow,
        );
      }
      // Letter in the gap before the sector.
      final la = _rad(startDeg - _gapDeg / 2);
      final tp = TextPainter(
        text: TextSpan(
          text: letter,
          style: labelStyle.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        c +
            Offset(math.cos(la), math.sin(la)) * orbitR -
            Offset(tp.width / 2, tp.height / 2),
      );
    }

    // ── Calorie reactor ring ────────────────────────────────────────────
    final calR = r - 44;
    const calW = 15.0;
    final calRect = Rect.fromCircle(center: c, radius: calR);
    final calColor = AppColors.calories;
    // Segmented track.
    const segs = 60;
    final seg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = calW
      ..color = calColor.withValues(alpha: hud.isDark ? 0.10 : 0.14);
    const segGap = 0.022;
    for (var i = 0; i < segs; i++) {
      final a0 = -math.pi / 2 + i / segs * 2 * math.pi + segGap / 2;
      canvas.drawArc(calRect, a0, 2 * math.pi / segs - segGap, false, seg);
    }
    final cp = v.calories.isFinite ? v.calories : 0.0;
    final fill = cp.clamp(0.0, 1.0);
    if (fill > 0.002) {
      final sweep = fill * 2 * math.pi;
      final shader = SweepGradient(
        startAngle: 0,
        endAngle: math.max(sweep, 0.01),
        colors: [calColor.withValues(alpha: 0.35), calColor],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(calRect);
      canvas.drawArc(
        calRect,
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = calW + 6
          ..color = calColor.withValues(alpha: 0.30 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );
      canvas.drawArc(
        calRect,
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = calW
          ..strokeCap = StrokeCap.butt
          ..shader = shader,
      );
      if (cp <= 1) _head(canvas, c, calR, -math.pi / 2 + sweep, calColor);
    }
    if (cp > 1) {
      final over = (cp - 1).clamp(0.0, 1.0);
      final sweep = over * 2 * math.pi;
      _glowArc(canvas, calRect, -math.pi / 2, sweep, overColor, calW, glow);
      _head(canvas, c, calR, -math.pi / 2 + sweep, overColor);
    }

    // Inner hairline with cardinal ticks.
    final innerR = calR - calW / 2 - 7;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = hud.hairline.withValues(alpha: hud.isDark ? 0.14 : 0.22);
    canvas.drawCircle(c, innerR, inner);
    for (var i = 0; i < 4; i++) {
      final a = i * math.pi / 2 - math.pi / 2;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * innerR,
        c + Offset(math.cos(a), math.sin(a)) * (innerR - 5),
        inner..strokeWidth = 1.4,
      );
    }
  }

  void _glowArc(
    Canvas canvas,
    Rect rect,
    double start,
    double sweep,
    Color color,
    double width,
    double glow,
  ) {
    if (sweep <= 0) return;
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 4
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.35 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  void _head(Canvas canvas, Offset c, double r, double a, Color color) {
    final p = c + Offset(math.cos(a), math.sin(a)) * r;
    canvas.drawCircle(
      p,
      9,
      Paint()
        ..color = color.withValues(alpha: 0.45 * hud.glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(p, 4.2, Paint()..color = Colors.white);
  }

  static double _rad(double deg) => deg * math.pi / 180;

  @override
  bool shouldRepaint(_MacroReactorPainter old) =>
      old.v != v || old.spin != spin || old.hud != hud;
}

// ---------------------------------------------------------------------------
// Liquid reactor (Hydration)
// ---------------------------------------------------------------------------

/// A ring with water sloshing inside: the level follows [progress] (0..1,
/// values above 1 render full) and the surface waves gently while on
/// screen. Reduced motion freezes the waves.
class LiquidReactor extends StatefulWidget {
  const LiquidReactor({
    super.key,
    required this.progress,
    this.size = 220,
    this.color = AppColors.water,
    this.child,
    this.semanticLabel,
    this.ring = true,
    this.childAlignment = Alignment.center,
  });

  /// Where [child] sits; lift it above the waterline for big readouts.
  final Alignment childAlignment;
  final double progress;
  final double size;
  final Color color;
  final Widget? child;
  final String? semanticLabel;

  /// Outer progress ring + bezel (off for tiny inline badges).
  final bool ring;

  @override
  State<LiquidReactor> createState() => _LiquidReactorState();
}

class _LiquidReactorState extends State<LiquidReactor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _wave.stop();
    } else if (!_wave.isAnimating) {
      unawaited(_wave.repeat());
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    final p = widget.progress.isFinite ? widget.progress.clamp(0.0, 1.0) : 0.0;
    return Semantics(
      label: widget.semanticLabel,
      value: widget.semanticLabel == null ? null : '${(p * 100).round()}%',
      child: SizedBox.square(
        dimension: widget.size,
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: p),
            duration: reduced ? Duration.zero : AppMotion.data,
            curve: AppMotion.emphasizedDecelerate,
            builder: (context, level, child) => AnimatedBuilder(
              animation: _wave,
              builder: (context, child) => CustomPaint(
                painter: _LiquidPainter(
                  level: level,
                  phase: _wave.value,
                  color: widget.color,
                  hud: hud,
                  ring: widget.ring,
                ),
                child: child,
              ),
              child: child,
            ),
            child: Align(alignment: widget.childAlignment, child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _LiquidPainter extends CustomPainter {
  _LiquidPainter({
    required this.level,
    required this.phase,
    required this.color,
    required this.hud,
    required this.ring,
  });

  final double level;
  final double phase;
  final Color color;
  final HudTheme hud;
  final bool ring;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final small = r < 40;
    final ringW = small ? 3.0 : 8.0;
    final ringR = ring ? r - (small ? 2 : 10) : r;
    final poolR = ring ? ringR - ringW / 2 - (small ? 3 : 8) : r - 1;

    if (ring) {
      if (!small) {
        // Bezel ticks.
        final tick = Paint()
          ..strokeWidth = 1
          ..color = hud.hairline.withValues(alpha: hud.isDark ? 0.22 : 0.3);
        for (var i = 0; i < 60; i++) {
          final a = i / 60 * 2 * math.pi;
          final long = i % 5 == 0;
          canvas.drawLine(
            c + Offset(math.cos(a), math.sin(a)) * (r - 1),
            c + Offset(math.cos(a), math.sin(a)) * (r - (long ? 6 : 3.5)),
            tick,
          );
        }
      }
      final rect = Rect.fromCircle(center: c, radius: ringR);
      canvas.drawCircle(
        c,
        ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringW
          ..color = color.withValues(alpha: hud.isDark ? 0.12 : 0.16),
      );
      if (level > 0.002) {
        canvas.drawArc(
          rect,
          -math.pi / 2,
          level * 2 * math.pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ringW + 4
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: 0.35 * hud.glowStrength)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawArc(
          rect,
          -math.pi / 2,
          level * 2 * math.pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ringW
            ..strokeCap = StrokeCap.round
            ..color = color,
        );
      }
    }

    // Glass pool.
    final pool = Rect.fromCircle(center: c, radius: poolR);
    canvas.drawCircle(
      c,
      poolR,
      Paint()..color = color.withValues(alpha: hud.isDark ? 0.05 : 0.07),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(pool));

    final surfaceY = pool.bottom - pool.height * level;
    final amp = math.max(1.5, poolR * 0.045) * (level <= 0 ? 0.3 : 1);
    final t = phase * 2 * math.pi;
    Path wave(double ampScale, double shift, double lengthScale) {
      final path = Path()..moveTo(pool.left, pool.bottom);
      final wl = pool.width * lengthScale;
      for (var x = pool.left; x <= pool.right + 1; x += 2) {
        final y =
            surfaceY +
            math.sin((x - pool.left) / wl * 2 * math.pi + t + shift) *
                amp *
                ampScale;
        path.lineTo(x, y);
      }
      path
        ..lineTo(pool.right, pool.bottom)
        ..close();
      return path;
    }

    if (level > 0) {
      canvas.drawPath(
        wave(0.8, math.pi * 0.9, 0.7),
        Paint()..color = color.withValues(alpha: 0.18),
      );
      final front = wave(1, 0, 0.95);
      canvas.drawPath(
        front,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.55),
              color.withValues(alpha: 0.22),
            ],
          ).createShader(Rect.fromLTRB(0, surfaceY - amp, 0, pool.bottom)),
      );
      // Bright meniscus.
      final line = Path();
      for (var x = pool.left; x <= pool.right + 1; x += 2) {
        final y =
            surfaceY +
            math.sin((x - pool.left) / (pool.width * 0.95) * 2 * math.pi + t) *
                amp;
        x == pool.left ? line.moveTo(x, y) : line.lineTo(x, y);
      }
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = small ? 1 : 1.6
          ..color = Color.lerp(
            color,
            Colors.white,
            0.45,
          )!.withValues(alpha: 0.9),
      );
      // Rising bubbles (deterministic).
      if (!small && level > 0.08) {
        final bubble = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.35);
        for (var i = 0; i < 6; i++) {
          final seed = (i * 0.37) % 1;
          final prog = (phase + seed) % 1;
          final x = pool.left + pool.width * (0.2 + 0.6 * ((i * 0.61) % 1));
          final y = pool.bottom - (pool.bottom - surfaceY) * prog;
          canvas.drawCircle(Offset(x, y), 1.6 + (i % 3), bubble);
        }
      }
    }
    canvas.restore();
    // Glass rim highlight.
    canvas.drawArc(
      pool.deflate(2),
      math.pi * 1.1,
      math.pi * 0.35,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = small ? 1 : 2
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: hud.isDark ? 0.08 : 0.4),
    );
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.level != level ||
      old.phase != phase ||
      old.color != color ||
      old.hud != hud;
}

// ---------------------------------------------------------------------------
// Small shared pieces
// ---------------------------------------------------------------------------

/// Thin proportional P/C/F energy bar (e.g. on food result cards).
class MacroSplitBar extends StatelessWidget {
  const MacroSplitBar({
    super.key,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.height = 4,
  });

  final double protein;
  final double carbs;
  final double fat;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = math.max(0.0, protein * 4);
    final c = math.max(0.0, carbs * 4);
    final f = math.max(0.0, fat * 9);
    final total = p + c + f;
    final hud = context.hud;
    if (total <= 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: hud.text.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(height),
        ),
      );
    }
    Widget part(double v, Color color) => Expanded(
      flex: math.max(1, (v / total * 1000).round()),
      child: Container(
        height: height,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(height),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4 * hud.glowStrength),
              blurRadius: 4,
            ),
          ],
        ),
      ),
    );
    return ExcludeSemantics(
      child: Row(
        children: [
          if (p > 0) part(p, AppColors.protein),
          if (c > 0) part(c, AppColors.carbs),
          if (f > 0) part(f, AppColors.fat),
        ],
      ),
    );
  }
}

/// Small glowing status glyph for a log entry's verification.
class VerifiedGlyph extends StatelessWidget {
  const VerifiedGlyph({super.key, required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Tooltip(
      message: label,
      child: Icon(icon, size: 14, color: hud.textMuted, semanticLabel: label),
    );
  }
}

/// Section label used inside nutrition cards: tiny HUD caption + optional
/// trailing widget.
class HudCaption extends StatelessWidget {
  const HudCaption(this.text, {super.key, this.trailing, this.color});

  final String text;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Row(
      children: [
        Container(
          width: 2,
          height: 10,
          margin: const EdgeInsets.only(right: 6),
          color: (color ?? hud.accent).withValues(alpha: 0.85),
        ),
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: hud.label(size: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?trailing,
      ],
    );
  }
}
