import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';

/// Loads and caches the app's fragment programs. Every consumer must cope
/// with `null` (shader unsupported, still loading, or disabled in tests) by
/// painting its fallback.
abstract final class HudShaders {
  /// Disabled under `flutter test` (headless rasteriser); flip for experiments.
  static bool enabled = !RuntimeEnv.isFlutterTest;

  static final Map<String, Future<ui.FragmentProgram?>> _cache = {};

  static Future<ui.FragmentProgram?> load(String asset) {
    if (!enabled) return Future.value(null);
    return _cache.putIfAbsent(asset, () async {
      try {
        return await ui.FragmentProgram.fromAsset(asset);
      } catch (_) {
        return null;
      }
    });
  }

  static const background = 'shaders/hud_background.frag';
  static const reactor = 'shaders/arc_reactor.frag';
}

/// One clock for every HUD animation so independent widgets (background,
/// orbs, the boot sequence) stay phase-locked across routes.
abstract final class HudClock {
  static final Stopwatch _sw = Stopwatch()..start();
  static double get seconds => _sw.elapsedMicroseconds / 1e6;
}

/// Drives a [ValueNotifier] with [HudClock] time, capped at [fps], paused
/// when the app is not resumed, when reduced motion is on, or when the
/// subtree is offstage (via [TickerMode]).
mixin HudTimeDriver<T extends StatefulWidget> on State<T>, TickerProvider {
  final ValueNotifier<double> hudTime = ValueNotifier(HudClock.seconds);
  late final Ticker _ticker = createTicker(_tick);
  late final AppLifecycleListener _lifecycle;
  Timer? _rearm;
  bool _resumed = true;
  bool _wantRun = false;

  /// Override to stop animating (e.g. `widget.animate == false`).
  bool get wantsTicks => true;
  int get fps => 30;

  // One vsync-aligned tick per paint, then sleep until the next paint is
  // due. Keeping the ticker running would schedule a frame on every vsync
  // (60-120 Hz), re-rasterising full-screen shaders at the display rate
  // regardless of [fps].
  void _tick(Duration _) {
    hudTime.value = HudClock.seconds;
    _ticker.stop();
    _rearm?.cancel();
    _rearm = Timer(Duration(microseconds: 1000000 ~/ fps), () {
      _rearm = null;
      if (mounted && _wantRun && !_ticker.isActive) _ticker.start();
    });
  }

  void syncTicker() {
    if (!mounted) return;
    final run = wantsTicks && _resumed && !AppMotion.reduced(context);
    _wantRun = run;
    if (run) {
      if (!_ticker.isActive && _rearm == null) _ticker.start();
    } else {
      _rearm?.cancel();
      _rearm = null;
      if (_ticker.isActive) _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    final s = SchedulerBinding.instance.lifecycleState;
    _resumed = s == null || s == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _resumed = state == AppLifecycleState.resumed;
        syncTicker();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncTicker();
  }

  @override
  void dispose() {
    _rearm?.cancel();
    _lifecycle.dispose();
    _ticker.dispose();
    hudTime.dispose();
    super.dispose();
  }
}

/// The living HUD canvas: a slow holographic nebula, faint hex grid,
/// twinkles, scanlines and vignette. GPU shader when available, painter
/// fallback otherwise (tests, unsupported devices). 30 fps cap; pauses when
/// the app is backgrounded or reduced motion is on.
///
/// The app root paints one instance behind the navigator; pages are
/// transparent on top of it.
class HudBackground extends StatefulWidget {
  const HudBackground({
    super.key,
    this.child,
    this.animate = true,
    this.intensity = 1,
  });

  final Widget? child;
  final bool animate;

  /// 0..1 multiplier on top of the theme's `nebulaIntensity`.
  final double intensity;

  @override
  State<HudBackground> createState() => _HudBackgroundState();
}

class _HudBackgroundState extends State<HudBackground>
    with SingleTickerProviderStateMixin, HudTimeDriver {
  ui.FragmentShader? _shader;

  @override
  bool get wantsTicks => widget.animate;

  @override
  void initState() {
    super.initState();
    unawaited(
      HudShaders.load(HudShaders.background).then((p) {
        if (p != null && mounted) setState(() => _shader = p.fragmentShader());
      }),
    );
  }

  @override
  void didUpdateWidget(HudBackground old) {
    super.didUpdateWidget(old);
    syncTicker();
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _BackgroundPainter(
              time: hudTime,
              shader: _shader,
              hud: hud,
              intensity: widget.intensity * hud.nebulaIntensity,
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({
    required this.time,
    required this.shader,
    required this.hud,
    required this.intensity,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final ui.FragmentShader? shader;
  final HudTheme hud;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final s = shader;
    if (s != null) {
      final a = hud.accent;
      s
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, time.value)
        ..setFloat(3, intensity)
        ..setFloat(4, a.r)
        ..setFloat(5, a.g)
        ..setFloat(6, a.b)
        ..setFloat(7, 1)
        ..setFloat(8, hud.canvasTop.r)
        ..setFloat(9, hud.canvasTop.g)
        ..setFloat(10, hud.canvasTop.b)
        ..setFloat(11, 1)
        ..setFloat(12, hud.canvasBottom.r)
        ..setFloat(13, hud.canvasBottom.g)
        ..setFloat(14, hud.canvasBottom.b)
        ..setFloat(15, 1);
      canvas.drawRect(rect, Paint()..shader = s);
      return;
    }
    HudBackgroundFallback.paint(canvas, size, time.value, hud, intensity);
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) =>
      old.shader != shader || old.hud != hud || old.intensity != intensity;
}

/// Painter version of the background shader (no GPU program needed).
/// Static layers are cached as pictures; only two soft nebula lobes move.
abstract final class HudBackgroundFallback {
  static ui.Picture? _grid;
  static Size? _gridSize;
  static Color? _gridColor;

  static void paint(
    Canvas canvas,
    Size size,
    double t,
    HudTheme hud,
    double intensity,
  ) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          hud.canvasTop,
          hud.canvasBottom,
        ]),
    );
    final a = hud.accent;
    final w = size.width;
    final h = size.height;
    // Reactor light from above.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(Offset(w * 0.5, -h * 0.06), w * 1.05, [
          a.withValues(alpha: 0.13 * intensity),
          a.withValues(alpha: 0),
        ]),
    );
    // Drifting nebula lobes.
    final p1 = Offset(
      w * (0.12 + 0.06 * math.sin(t * 0.05)),
      h * (0.34 + 0.04 * math.cos(t * 0.04)),
    );
    canvas.drawCircle(
      p1,
      w * 0.75,
      Paint()
        ..shader = ui.Gradient.radial(p1, w * 0.75, [
          a.withValues(alpha: 0.06 * intensity),
          a.withValues(alpha: 0),
        ]),
    );
    final p2 = Offset(
      w * (0.92 - 0.05 * math.cos(t * 0.045)),
      h * (0.72 + 0.03 * math.sin(t * 0.05)),
    );
    const deep = Color(0xFF2448B8);
    canvas.drawCircle(
      p2,
      w * 0.85,
      Paint()
        ..shader = ui.Gradient.radial(p2, w * 0.85, [
          deep.withValues(alpha: 0.10 * intensity),
          deep.withValues(alpha: 0),
        ]),
    );
    // Hex grid (cached).
    if (_grid == null || _gridSize != size || _gridColor != hud.gridColor) {
      _grid?.dispose();
      _grid = _recordGrid(size, hud.gridColor);
      _gridSize = size;
      _gridColor = hud.gridColor;
    }
    canvas.drawPicture(_grid!);
    // Vignette.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(w * 0.5, h * 0.42),
          math.max(w, h) * 0.75,
          [
            const Color(0x00000000),
            Color(hud.isDark ? 0x66000000 : 0x14000000),
          ],
          const [0.55, 1],
        ),
    );
  }

  static ui.Picture _recordGrid(Size size, Color color) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const r = 25.4;
    final cw = math.sqrt(3) * r;
    final path = Path();
    for (var row = -1; row * r * 1.5 < size.height * 0.75; row++) {
      final y = row * r * 1.5;
      final off = row.isOdd ? cw / 2 : 0.0;
      for (var x = -cw + off; x < size.width + cw; x += cw) {
        path.addPolygon([
          for (var i = 0; i < 6; i++)
            Offset(
              x + r * math.cos(-math.pi / 2 + i * math.pi / 3),
              y + r * math.sin(-math.pi / 2 + i * math.pi / 3),
            ),
        ], true);
      }
    }
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height * 0.75),
          [color, color.withValues(alpha: 0)],
        ),
    );
    return rec.endRecording();
  }
}
