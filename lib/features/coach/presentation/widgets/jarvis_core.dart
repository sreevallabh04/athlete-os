import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/widgets/widgets.dart';

/// The Coach's centrepiece: the shared [JarvisOrb] wrapped in a cinematic
/// HUD halo that reacts to what the assistant is doing.
///
/// * idle – a slowly rotating reticle with four bracket notches
/// * listening – a glow ring that swells with the live microphone [level]
/// * thinking – a segmented scanner sweeping around the core
/// * speaking – an arc that fills with TTS progress and a ripple on every
///   spoken word ([wordTick])
///
/// Freezes with reduced motion. Tap/long-press are forwarded for
/// push-to-talk.
class JarvisCore extends StatefulWidget {
  const JarvisCore({
    super.key,
    required this.state,
    this.size = 200,
    this.level,
    this.speakProgress = 0,
    this.wordTick = 0,
    this.color,
    this.semanticLabel,
  });

  final OrbState state;

  /// Orb diameter; the halo extends ~25 % beyond it.
  final double size;
  final Stream<double>? level;
  final double speakProgress;
  final int wordTick;
  final Color? color;
  final String? semanticLabel;

  @override
  State<JarvisCore> createState() => _JarvisCoreState();
}

class _JarvisCoreState extends State<JarvisCore>
    with TickerProviderStateMixin, HudTimeDriver {
  StreamSubscription<double>? _sub;
  double _level = 0;
  double _target = 0;
  final _ripples = <double>[];
  double _lastT = HudClock.seconds;

  // Smoothed state weights, so the halo cross-fades like the orb does.
  final _w = List<double>.filled(OrbState.values.length, 0);

  @override
  int get fps => 60;

  @override
  void initState() {
    super.initState();
    _w[widget.state.index] = 1;
    _subscribe();
    hudTime.addListener(_step);
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.level?.listen((v) => _target = v.clamp(0.0, 1.0));
  }

  void _step() {
    final t = hudTime.value;
    final dt = (t - _lastT).clamp(0.0, 0.1);
    _lastT = t;
    final k = 1 - math.exp(-dt * 6);
    for (var i = 0; i < _w.length; i++) {
      _w[i] += ((i == widget.state.index ? 1.0 : 0.0) - _w[i]) * k;
    }
    _level += (_target - _level) * (1 - math.exp(-dt * 14));
    _ripples.removeWhere((r) => t - r > 0.9);
  }

  @override
  void didUpdateWidget(JarvisCore old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) _subscribe();
    if (old.wordTick != widget.wordTick &&
        widget.state == OrbState.speaking &&
        _ripples.length < 6) {
      _ripples.add(hudTime.value);
    }
    if (old.state != widget.state && AppMotion.reduced(context)) {
      for (var i = 0; i < _w.length; i++) {
        _w[i] = i == widget.state.index ? 1 : 0;
      }
    }
    if (widget.state != OrbState.listening) _target = 0;
  }

  @override
  void dispose() {
    hudTime.removeListener(_step);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final color = widget.color ?? hud.jarvis;
    final outer = widget.size * 1.42;
    return SizedBox.square(
      dimension: outer,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _HaloPainter(
                  time: hudTime,
                  color: color,
                  weights: _w,
                  level: () => _level,
                  progress: widget.speakProgress,
                  ripples: _ripples,
                  orbRadius: widget.size / 2,
                  glow: hud.glowStrength,
                ),
              ),
            ),
          ),
          JarvisOrb(
            state: widget.state,
            size: widget.size,
            level: widget.level,
            color: color,
            semanticLabel: widget.semanticLabel,
          ),
        ],
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({
    required this.time,
    required this.color,
    required this.weights,
    required this.level,
    required this.progress,
    required this.ripples,
    required this.orbRadius,
    required this.glow,
  }) : super(repaint: time);

  final ValueNotifier<double> time;
  final Color color;
  final List<double> weights;
  final double Function() level;
  final double progress;
  final List<double> ripples;
  final double orbRadius;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final c = size.center(Offset.zero);
    final r = orbRadius * 1.08;
    final wListen = weights[OrbState.listening.index];
    final wThink = weights[OrbState.thinking.index];
    final wSpeak = weights[OrbState.speaking.index];
    final lv = level();
    final stroke = math.max(1.0, orbRadius * 0.012);

    // ── Reticle: two counter-rotating dashed arcs + bracket notches ───────
    final ret = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.22);
    final spin = t * (0.12 + 0.5 * wThink);
    for (var i = 0; i < 24; i++) {
      final a = spin + i * math.pi / 12;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 1.12),
        a,
        math.pi / 24,
        false,
        ret,
      );
    }
    final notch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.8
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);
    for (var i = 0; i < 4; i++) {
      final a = -spin * 0.6 + i * math.pi / 2 + math.pi / 4;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 1.22),
        a - 0.12,
        0.24,
        false,
        notch,
      );
    }

    // ── Listening: glow ring that swells with the voice ───────────────────
    if (wListen > 0.01) {
      final rr = r * (1.02 + 0.12 * lv);
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * (2 + 5 * lv)
          ..color = color.withValues(alpha: (0.18 + 0.5 * lv) * wListen)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 10 * lv * glow),
      );
      final bars = Paint()
        ..strokeWidth = stroke * 1.3
        ..strokeCap = StrokeCap.round
        ..color = Color.lerp(
          color,
          Colors.white,
          0.25,
        )!.withValues(alpha: 0.75 * wListen);
      const n = 90;
      for (var i = 0; i < n; i++) {
        final a = i * 2 * math.pi / n;
        final wob =
            0.5 + 0.5 * math.sin(a * 4 + t * 5) * math.cos(a * 7 - t * 3.1);
        final len = r * (0.012 + (0.025 + 0.08 * lv) * wob) * wListen;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * r * 1.2, c + d * (r * 1.2 + len), bars);
      }
    }

    // ── Thinking: segmented scanner ────────────────────────────────────────
    if (wThink > 0.01) {
      final head = t * 2.4;
      for (var i = 0; i < 14; i++) {
        final a = head - i * 0.09;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r * 1.3),
          a,
          0.06,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 2.2
            ..color = color.withValues(alpha: (1 - i / 14) * 0.9 * wThink),
        );
      }
      // Data blips along the outer ring.
      for (var i = 0; i < 6; i++) {
        final ph = (t * 0.7 + i / 6) % 1.0;
        final a = i * 1.7 + t * 0.4;
        final p = c + Offset(math.cos(a), math.sin(a)) * r * (1.18 + 0.1 * ph);
        canvas.drawCircle(
          p,
          stroke * 1.4,
          Paint()..color = color.withValues(alpha: (1 - ph) * 0.8 * wThink),
        );
      }
    }

    // ── Speaking: progress arc + word ripples ──────────────────────────────
    if (wSpeak > 0.01) {
      final rect = Rect.fromCircle(center: c, radius: r * 1.3);
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.4
          ..color = color.withValues(alpha: 0.12 * wSpeak),
      );
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 2.4
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.9 * wSpeak),
      );
      for (final start in ripples) {
        final ph = ((t - start) / 0.9).clamp(0.0, 1.0);
        canvas.drawCircle(
          c,
          r * (1.0 + 0.32 * ph),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 2 * (1 - ph)
            ..color = color.withValues(alpha: 0.6 * (1 - ph) * wSpeak),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.color != color || old.progress != progress;
}
