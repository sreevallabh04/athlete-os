import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/habit_models.dart';

/// 24-hour quiet-hours dial. Midnight sits at the top, noon at the bottom.
/// The quiet window is a glowing arc between two draggable handles (moon =
/// start, sun = end) that snap to 15 minutes with a selection tick per step
/// and a firmer tick on the hour. Wake / sleep from the profile are marked
/// on the bezel for orientation.
///
/// Changes stream through [onChanging] while dragging and commit through
/// [onChanged] when the finger lifts.
class QuietHoursDial extends StatefulWidget {
  const QuietHoursDial({
    super.key,
    required this.start,
    required this.end,
    required this.onChanged,
    this.onChanging,
    this.wakeMinutes,
    this.sleepMinutes,
    this.size = 260,
  });

  final int start;
  final int end;
  final void Function(int start, int end) onChanged;
  final void Function(int start, int end)? onChanging;
  final int? wakeMinutes;
  final int? sleepMinutes;
  final double size;

  @override
  State<QuietHoursDial> createState() => _QuietHoursDialState();
}

enum _Handle { start, end }

class _QuietHoursDialState extends State<QuietHoursDial> {
  late int _start = widget.start;
  late int _end = widget.end;
  _Handle? _active;

  static const _step = 15;

  @override
  void didUpdateWidget(QuietHoursDial old) {
    super.didUpdateWidget(old);
    if (_active == null) {
      _start = widget.start;
      _end = widget.end;
    }
  }

  double _angleOf(int minutes) => minutes / 1440 * math.pi * 2 - math.pi / 2;

  int _minutesAt(Offset local, double size) {
    final c = Offset(size / 2, size / 2);
    final v = local - c;
    var a = math.atan2(v.dy, v.dx) + math.pi / 2;
    if (a < 0) a += math.pi * 2;
    final m = (a / (math.pi * 2) * 1440).round();
    return ((m / _step).round() * _step) % 1440;
  }

  Offset _posOf(int minutes, double size) {
    final r = size * _QuietDialPainter.ringFactor;
    final a = _angleOf(minutes);
    return Offset(size / 2, size / 2) + Offset(math.cos(a), math.sin(a)) * r;
  }

  void _onStart(DragStartDetails d) {
    final s = widget.size;
    final ds = (d.localPosition - _posOf(_start, s)).distance;
    final de = (d.localPosition - _posOf(_end, s)).distance;
    final nearest = ds <= de ? _Handle.start : _Handle.end;
    if (math.min(ds, de) > s * 0.2) return; // grab handles, not the void
    Haptics.light();
    setState(() => _active = nearest);
  }

  void _onUpdate(DragUpdateDetails d) {
    final h = _active;
    if (h == null) return;
    final m = _minutesAt(d.localPosition, widget.size);
    final other = h == _Handle.start ? _end : _start;
    if (m == other) return; // an empty window is not a window
    final old = h == _Handle.start ? _start : _end;
    if (m == old) return;
    if (m % 60 == 0) {
      Haptics.light();
    } else {
      Haptics.selection();
    }
    setState(() {
      if (h == _Handle.start) {
        _start = m;
      } else {
        _end = m;
      }
    });
    widget.onChanging?.call(_start, _end);
  }

  void _onEnd([DragEndDetails? _]) {
    if (_active == null) return;
    setState(() => _active = null);
    Haptics.medium();
    widget.onChanged(_start, _end);
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final s = widget.size;
    final dur = ((_end - _start) % 1440 + 1440) % 1440;
    final h = dur ~/ 60;
    final m = dur % 60;
    final durText = m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')}';
    return Semantics(
      label:
          'Quiet hours from ${formatMinutes(_start)} to ${formatMinutes(_end)}, '
          '$durText',
      hint: 'Drag the moon or sun handle to adjust',
      child: GestureDetector(
        onPanStart: _onStart,
        onPanUpdate: _onUpdate,
        onPanEnd: _onEnd,
        onPanCancel: _onEnd,
        child: SizedBox.square(
          dimension: s,
          child: CustomPaint(
            painter: _QuietDialPainter(
              start: _start,
              end: _end,
              wake: widget.wakeMinutes,
              sleep: widget.sleepMinutes,
              hud: hud,
              active: _active,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('QUIET', style: hud.label(size: 11)),
                  const SizedBox(height: 4),
                  Text(
                    '${formatMinutes(_start)} → ${formatMinutes(_end)}',
                    style: hud
                        .mono(size: 16, color: hud.text)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    durText,
                    style: hud.number(size: 30, color: hud.accentInk),
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

class _QuietDialPainter extends CustomPainter {
  _QuietDialPainter({
    required this.start,
    required this.end,
    required this.wake,
    required this.sleep,
    required this.hud,
    required this.active,
  });

  final int start;
  final int end;
  final int? wake;
  final int? sleep;
  final HudTheme hud;
  final _Handle? active;

  static const ringFactor = 0.39;

  double _a(int m) => m / 1440 * math.pi * 2 - math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final r = s * ringFactor;
    final accent = hud.accent;
    const night = Color(0xFF8F94FF);

    // Hour ticks + labels at 00/06/12/18.
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < 96; i++) {
      final a = i / 96 * math.pi * 2 - math.pi / 2;
      final hour = i % 4 == 0;
      final major = i % 24 == 0;
      final dir = Offset(math.cos(a), math.sin(a));
      final outer = s * 0.485;
      final len = major ? s * 0.045 : (hour ? s * 0.028 : s * 0.012);
      tick
        ..strokeWidth = major ? 2 : 1
        ..color = hud.hairline.withValues(
          alpha: major ? 0.6 : (hour ? 0.32 : 0.16),
        );
      canvas.drawLine(c + dir * outer, c + dir * (outer - len), tick);
    }
    final labelStyle = AppTypography.mono(hud.textMuted, size: 10);
    for (final (m, text) in const [
      (0, '00'),
      (360, '06'),
      (720, '12'),
      (1080, '18'),
    ]) {
      int gap(int x) {
        final d = (x - m).abs() % 1440;
        return math.min(d, 1440 - d);
      }

      // Never draw a label under a handle.
      if (gap(start) < 100 || gap(end) < 100) continue;
      final a = _a(m);
      final p = c + Offset(math.cos(a), math.sin(a)) * (s * 0.395);
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // Labels sit just inside the ring, nudged towards the centre.
      final inward = (c - p) / (c - p).distance * (s * 0.07);
      tp.paint(canvas, p + inward - Offset(tp.width / 2, tp.height / 2));
    }

    // Track.
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.06
        ..color = hud.hairline.withValues(alpha: hud.isDark ? 0.07 : 0.12),
    );

    // Quiet arc (start → end, clockwise).
    final sweep = (((end - start) % 1440 + 1440) % 1440) / 1440 * math.pi * 2;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.06
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        transform: GradientRotation(_a(start)),
        colors: [
          night.withValues(alpha: 0.95),
          accent.withValues(alpha: 0.9),
          accent.withValues(alpha: 0.9),
        ],
        stops: [0, (sweep / (math.pi * 2)).clamp(0.01, 1.0), 1],
      ).createShader(rect);
    canvas.drawArc(
      rect,
      _a(start),
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.09
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: 0.18 * hud.glowStrength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );
    canvas.drawArc(rect, _a(start), sweep, false, arcPaint);

    // Profile markers (wake / sleep) on the outer bezel.
    void marker(int? m, Color color) {
      if (m == null) return;
      final a = _a(m);
      final p = c + Offset(math.cos(a), math.sin(a)) * (s * 0.465);
      canvas.drawCircle(p, s * 0.014, Paint()..color = color);
      canvas.drawCircle(
        p,
        s * 0.03,
        Paint()
          ..color = color.withValues(alpha: 0.3 * hud.glowStrength)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.015),
      );
    }

    marker(wake, AppColors.gold);
    marker(sleep, night);

    // Handles.
    void handle(int m, IconData icon, bool isActive, Color color) {
      final a = _a(m);
      final p = c + Offset(math.cos(a), math.sin(a)) * r;
      final hr = s * (isActive ? 0.068 : 0.058);
      canvas.drawCircle(
        p,
        hr * 1.6,
        Paint()
          ..color = color.withValues(
            alpha: (isActive ? 0.45 : 0.25) * hud.glowStrength,
          )
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, hr * 0.8),
      );
      canvas.drawCircle(
        p,
        hr,
        Paint()..color = hud.isDark ? const Color(0xFF0A111D) : Colors.white,
      );
      canvas.drawCircle(
        p,
        hr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: hr * 1.1,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }

    handle(end, Icons.wb_sunny_rounded, active == _Handle.end, AppColors.gold);
    handle(start, Icons.bedtime_rounded, active == _Handle.start, night);
  }

  @override
  bool shouldRepaint(_QuietDialPainter old) =>
      old.start != start ||
      old.end != end ||
      old.wake != wake ||
      old.sleep != sleep ||
      old.hud != hud ||
      old.active != active;
}
