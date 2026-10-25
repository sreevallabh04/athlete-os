import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import 'hud_background.dart';

/// What the assistant is doing. Drives [JarvisOrb]'s animation.
enum OrbState { idle, listening, thinking, speaking }

/// The assistant's presence: an animated reactor orb.
///
/// * idle – slow breathing core, lazily rotating rings
/// * listening – a radial waveform that reacts to [level] (0..1 mic level)
/// * thinking – three particles orbiting with light trails
/// * speaking – the core pulses and emits soft rings
///
/// States cross-fade smoothly. Uses the `arc_reactor.frag` shader for the
/// core when available, a gradient painter otherwise.
///
/// ```dart
/// JarvisOrb(state: OrbState.listening, level: mic.levelStream, size: 180)
/// ```
class JarvisOrb extends StatefulWidget {
  const JarvisOrb({
    super.key,
    this.state = OrbState.idle,
    this.size = 160,
    this.level,
    this.color,
    this.fps = 60,
    this.semanticLabel,
  });

  final OrbState state;
  final double size;

  /// Microphone level stream (0..1), used while [OrbState.listening].
  final Stream<double>? level;
  final Color? color;

  /// Repaint cap. Use 30 for small decorative orbs (dock).
  final int fps;
  final String? semanticLabel;

  @override
  State<JarvisOrb> createState() => _JarvisOrbState();
}

class _JarvisOrbState extends State<JarvisOrb>
    with TickerProviderStateMixin, HudTimeDriver {
  ui.FragmentShader? _shader;
  StreamSubscription<double>? _sub;
  double _targetLevel = 0;
  final _weights = List<double>.filled(OrbState.values.length, 0);
  double _level = 0;
  double _lastT = HudClock.seconds;

  @override
  int get fps => widget.fps;

  @override
  void initState() {
    super.initState();
    _weights[widget.state.index] = 1;
    _subscribe();
    hudTime.addListener(_step);
    unawaited(
      HudShaders.load(HudShaders.reactor).then((p) {
        if (p != null && mounted) setState(() => _shader = p.fragmentShader());
      }),
    );
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.level?.listen((v) => _targetLevel = v.clamp(0.0, 1.0));
  }

  void _step() {
    final now = hudTime.value;
    final dt = (now - _lastT).clamp(0.0, 0.1);
    _lastT = now;
    final k = 1 - math.exp(-dt * 7);
    for (var i = 0; i < _weights.length; i++) {
      final target = i == widget.state.index ? 1.0 : 0.0;
      _weights[i] += (target - _weights[i]) * k;
    }
    final lk = 1 - math.exp(-dt * 18);
    _level += (_targetLevel - _level) * lk;
  }

  @override
  void didUpdateWidget(JarvisOrb old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) _subscribe();
    if (old.state != widget.state && AppMotion.reduced(context)) {
      // Reduced motion / paused: jump straight to the new state.
      for (var i = 0; i < _weights.length; i++) {
        _weights[i] = i == widget.state.index ? 1 : 0;
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    hudTime.removeListener(_step);
    _sub?.cancel();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final color = widget.color ?? hud.accent;
    final label =
        widget.semanticLabel ??
        switch (widget.state) {
          OrbState.idle => 'Assistant ready',
          OrbState.listening => 'Assistant listening',
          OrbState.thinking => 'Assistant thinking',
          OrbState.speaking => 'Assistant speaking',
        };
    return Semantics(
      label: label,
      liveRegion: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: _OrbPainter(
              time: hudTime,
              color: color,
              shader: _shader,
              weights: _weights,
              level: () => _level,
              dark: hud.isDark,
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.time,
    required this.color,
    required this.shader,
    required this.weights,
    required this.level,
    required this.dark,
  }) : super(repaint: time);

  final ValueNotifier<double> time;
  final Color color;
  final ui.FragmentShader? shader;
  final List<double> weights;
  final double Function() level;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    final wIdle = weights[OrbState.idle.index];
    final wListen = weights[OrbState.listening.index];
    final wThink = weights[OrbState.thinking.index];
    final wSpeak = weights[OrbState.speaking.index];
    final lv = level();
    final speakPulse = 0.5 + 0.5 * math.sin(t * 7.5) * math.sin(t * 2.3 + 1);
    final energy =
        (0.25 * wIdle +
                (0.4 + 0.6 * lv) * wListen +
                0.5 * wThink +
                (0.45 + 0.55 * speakPulse) * wSpeak)
            .clamp(0.0, 1.0);
    final breathe = 0.5 + 0.5 * math.sin(t * 1.6);

    // ── Core ───────────────────────────────────────────────────────────────
    final coreR = r * (0.62 + 0.05 * breathe * wIdle + 0.08 * energy);
    final s = shader;
    if (s != null) {
      final rect = Rect.fromCircle(center: c, radius: coreR);
      s
        ..setFloat(0, rect.width)
        ..setFloat(1, rect.height)
        ..setFloat(2, t)
        ..setFloat(3, energy)
        ..setFloat(4, color.r)
        ..setFloat(5, color.g)
        ..setFloat(6, color.b)
        ..setFloat(7, 1);
      canvas.save();
      canvas.translate(rect.left, rect.top);
      canvas.drawRect(Offset.zero & rect.size, Paint()..shader = s);
      canvas.restore();
    } else {
      canvas.drawCircle(
        c,
        coreR,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            coreR,
            [
              color.withValues(alpha: 0.30 + 0.35 * energy),
              color.withValues(alpha: 0.10 + 0.1 * energy),
              color.withValues(alpha: 0),
            ],
            const [0, 0.45, 1],
          ),
      );
      canvas.drawCircle(
        c,
        r * (0.16 + 0.06 * energy),
        Paint()
          ..color = Color.lerp(color, Colors.white, 0.8)!
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08),
      );
      canvas.drawCircle(
        c,
        r * (0.09 + 0.03 * energy),
        Paint()..color = Colors.white.withValues(alpha: 0.95),
      );
    }

    final stroke = math.max(1.0, r * 0.02);

    // ── Inner rotating segments ────────────────────────────────────────────
    final spin = t * (0.35 + 1.4 * wThink + 0.5 * wSpeak);
    final innerRect = Rect.fromCircle(center: c, radius: r * 0.44);
    final seg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.6
      ..strokeCap = StrokeCap.butt
      ..color = color.withValues(alpha: 0.75);
    for (var i = 0; i < 6; i++) {
      canvas.drawArc(
        innerRect,
        spin + i * math.pi / 3,
        math.pi / 3 - 0.28,
        false,
        seg,
      );
    }

    // ── Outer ring + counter-rotating arcs ─────────────────────────────────
    canvas.drawCircle(
      c,
      r * 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.6
        ..color = color.withValues(alpha: 0.28),
    );
    final outerRect = Rect.fromCircle(center: c, radius: r * 0.8);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.85);
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
        outerRect,
        -spin * 0.6 + i * 2 * math.pi / 3,
        0.55,
        false,
        arc,
      );
    }

    // ── Tick bezel ─────────────────────────────────────────────────────────
    final tick = Paint()
      ..strokeWidth = math.max(0.8, stroke * 0.5)
      ..color = color.withValues(alpha: 0.35);
    const n = 48;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      final dir = Offset(math.cos(a), math.sin(a));
      final major = i % 4 == 0;
      canvas.drawLine(
        c + dir * r * (major ? 0.88 : 0.91),
        c + dir * r * 0.96,
        tick,
      );
    }

    // ── Listening: radial waveform ─────────────────────────────────────────
    if (wListen > 0.01) {
      final bar = Paint()
        ..strokeWidth = math.max(1.2, r * 0.025)
        ..strokeCap = StrokeCap.round
        ..color = Color.lerp(
          color,
          Colors.white,
          0.3,
        )!.withValues(alpha: 0.9 * wListen);
      const bars = 56;
      for (var i = 0; i < bars; i++) {
        final a = i * 2 * math.pi / bars;
        final wobble =
            0.5 + 0.5 * math.sin(a * 3 + t * 6) * math.cos(a * 5 - t * 4.3);
        final len = r * (0.03 + (0.06 + 0.16 * lv) * wobble) * wListen;
        final dir = Offset(math.cos(a), math.sin(a));
        final base = r * 0.6;
        canvas.drawLine(c + dir * base, c + dir * (base + len), bar);
      }
    }

    // ── Thinking: orbiting particles with trails ───────────────────────────
    if (wThink > 0.01) {
      for (var i = 0; i < 3; i++) {
        final speed = 1.6 + i * 0.55;
        final orbit = r * (0.62 + i * 0.07);
        final a = t * speed + i * 2.1;
        final rect = Rect.fromCircle(center: c, radius: orbit);
        canvas.drawArc(
          rect,
          a - 0.9,
          0.9,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 1.3
            ..strokeCap = StrokeCap.round
            ..shader = ui.Gradient.sweep(
              c,
              [
                color.withValues(alpha: 0),
                color.withValues(alpha: 0.8 * wThink),
              ],
              const [0, 1],
              TileMode.clamp,
              a - 0.9,
              a,
            ),
        );
        final p = c + Offset(math.cos(a), math.sin(a)) * orbit;
        canvas.drawCircle(
          p,
          r * 0.035,
          Paint()..color = Colors.white.withValues(alpha: 0.95 * wThink),
        );
        canvas.drawCircle(
          p,
          r * 0.07,
          Paint()
            ..color = color.withValues(alpha: 0.5 * wThink)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.04),
        );
      }
    }

    // ── Speaking: emitted rings ────────────────────────────────────────────
    if (wSpeak > 0.01) {
      for (var i = 0; i < 2; i++) {
        final ph = ((t * 0.9) + i * 0.5) % 1.0;
        canvas.drawCircle(
          c,
          r * (0.35 + 0.6 * ph),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * (1.6 - ph)
            ..color = color.withValues(alpha: 0.55 * (1 - ph) * wSpeak),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.color != color || old.shader != shader || old.dark != dark;
}
