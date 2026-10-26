import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The Athlete OS mark: a segmented hexagon "reactor housing" around a
/// faceted Λ monogram whose crossbar is a white-hot energy cell.
///
/// Original artwork (no third-party marks). The same painter renders the
/// launcher icon (`tool/render_icon_test.dart`), the native splash image and
/// the boot sequence, so the cold-start hand-off is pixel-continuous.
class AthleteEmblem extends StatelessWidget {
  const AthleteEmblem({
    super.key,
    this.size = 120,
    this.glow = 1,
    this.draw = 1,
    this.detail = false,
    this.semanticLabel = 'Athlete OS',
  });

  final double size;

  /// 0..1+ bloom multiplier.
  final double glow;

  /// 0..1 draw-in progress (hex segments trace, monogram fades up).
  final double draw;

  /// Adds the outer tick ring (large sizes only).
  final bool detail;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    image: semanticLabel != null,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: EmblemPainter(glow: glow, draw: draw, detail: detail),
      ),
    ),
  );
}

/// Visual variants of [EmblemPainter].
enum EmblemStyle {
  /// Full colour with bloom (app, splash).
  color,

  /// Flat white silhouette (themed / monochrome icon, notifications).
  mono,
}

class EmblemPainter extends CustomPainter {
  const EmblemPainter({
    this.glow = 1,
    this.draw = 1,
    this.detail = false,
    this.style = EmblemStyle.color,
    this.scale = 1,
  });

  final double glow;
  final double draw;
  final bool detail;
  final EmblemStyle style;

  /// Fraction of the canvas the emblem occupies (used for icon safe zones).
  final double scale;

  // Stark palette: red housing, gold monogram, white-hot cell.
  static const _redHot = Color(0xFFFF8A7E);
  static const _red = AppColors.red;
  static const _redDeep = Color(0xFF8E1A1F);
  static const _goldHot = Color(0xFFFFE7B0);
  static const _gold = AppColors.gold;
  static const _bronze = Color(0xFFB8741E);

  /// Hexagon vertices (pointy top) on a unit circle of radius [r].
  static List<Offset> hex(double r) => [
    for (var i = 0; i < 6; i++)
      Offset(
        r * math.cos(-math.pi / 2 + i * math.pi / 3),
        r * math.sin(-math.pi / 2 + i * math.pi / 3),
      ),
  ];

  /// The Λ monogram as two facets (left, right) in unit space.
  static (Path, Path) monogram() {
    const apex = Offset(0, -0.56);
    const notch = Offset(0, -0.17);
    const lo = Offset(-0.47, 0.44);
    const li = Offset(-0.285, 0.44);
    final left = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(notch.dx, notch.dy)
      ..lineTo(li.dx, li.dy)
      ..lineTo(lo.dx, lo.dy)
      ..close();
    final right = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(-lo.dx, lo.dy)
      ..lineTo(-li.dx, li.dy)
      ..lineTo(notch.dx, notch.dy)
      ..close();
    return (left, right);
  }

  /// The crossbar energy cell, floating between the legs.
  static RRect cell() => RRect.fromRectAndRadius(
    Rect.fromCenter(center: const Offset(0, 0.165), width: 0.30, height: 0.085),
    const Radius.circular(0.0425),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height) / 2 * scale;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(s);
    final d = draw.clamp(0.0, 1.0);
    final mono = style == EmblemStyle.mono;
    final g = glow.clamp(0.0, 3.0);

    // ── Outer tick ring (detail only) ──────────────────────────────────────
    if (detail && !mono) {
      final tick = Paint()
        ..color = _gold.withValues(alpha: 0.35 * d)
        ..strokeWidth = 0.012
        ..strokeCap = StrokeCap.round;
      const n = 72;
      for (var i = 0; i < (n * d).round(); i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / n;
        final major = i % 6 == 0;
        final r0 = major ? 0.93 : 0.95;
        canvas.drawLine(
          Offset(math.cos(a) * r0, math.sin(a) * r0),
          Offset(math.cos(a) * 0.99, math.sin(a) * 0.99),
          tick,
        );
      }
    }

    // ── Hex housing: six edges with gaps at the vertices ───────────────────
    final outer = hex(0.84);
    const gap = 0.07;
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.075
      ..strokeCap = StrokeCap.butt;
    if (mono) {
      edgePaint.color = Colors.white;
    } else {
      edgePaint.shader = ui.Gradient.linear(
        const Offset(0, -0.9),
        const Offset(0, 0.9),
        [_redHot, _red, _redDeep],
        [0, 0.45, 1],
      );
    }
    final hexPath = Path();
    for (var i = 0; i < 6; i++) {
      final a = outer[i];
      final b = outer[(i + 1) % 6];
      final local = ((d * 6) - i).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final p0 = Offset.lerp(a, b, gap)!;
      final p1 = Offset.lerp(a, b, gap + (1 - 2 * gap) * local)!;
      hexPath
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p1.dx, p1.dy);
    }
    if (!mono && g > 0) {
      canvas.drawPath(
        hexPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.075
          ..color = _red.withValues(alpha: 0.55 * math.min(1, g))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.06),
      );
    }
    canvas.drawPath(hexPath, edgePaint);

    // Vertex nodes: tiny squares where the edges break.
    if (!mono) {
      final node = Paint()..color = _goldHot.withValues(alpha: 0.9 * d);
      for (final v in hex(0.84)) {
        canvas.drawCircle(v, 0.018, node);
      }
    }

    // Inner plate + hairline hex.
    if (!mono) {
      final inner = hex(0.70);
      final p = Path()..addPolygon(inner, true);
      canvas.drawPath(
        p,
        Paint()
          ..shader = ui.Gradient.radial(const Offset(0, -0.1), 0.8, [
            const Color(0xFF3A1416).withValues(alpha: 0.75 * d),
            const Color(0xFF120B0C).withValues(alpha: 0.35 * d),
          ]),
      );
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.012
          ..color = _gold.withValues(alpha: 0.28 * d),
      );
    }

    // ── Monogram ───────────────────────────────────────────────────────────
    final mAlpha = ((d - 0.35) / 0.65).clamp(0.0, 1.0);
    if (mAlpha > 0) {
      final (left, right) = monogram();
      if (!mono && g > 0) {
        final bloom = Paint()
          ..color = _gold.withValues(alpha: 0.40 * mAlpha * math.min(1, g))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.08);
        canvas.drawPath(left, bloom);
        canvas.drawPath(right, bloom);
      }
      if (mono) {
        final white = Paint()..color = Colors.white;
        canvas.drawPath(left, white);
        canvas.drawPath(right, white);
      } else {
        // Faceted lighting: left facet catches the light, right is in shade.
        canvas.drawPath(
          left,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, -0.56),
              const Offset(-0.3, 0.44),
              [
                Colors.white.withValues(alpha: mAlpha),
                _goldHot.withValues(alpha: mAlpha),
                _gold.withValues(alpha: mAlpha),
              ],
              [0, 0.35, 1],
            ),
        );
        canvas.drawPath(
          right,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, -0.56),
              const Offset(0.3, 0.44),
              [
                _gold.withValues(alpha: mAlpha),
                const Color(0xFFDD9A34).withValues(alpha: mAlpha),
                _bronze.withValues(alpha: mAlpha),
              ],
              [0, 0.5, 1],
            ),
        );
      }

      // Energy cell.
      final c = cell();
      if (mono) {
        canvas.drawRRect(c, Paint()..color = Colors.white);
      } else {
        if (g > 0) {
          canvas.drawRRect(
            c.inflate(0.03),
            Paint()
              ..color = _goldHot.withValues(
                alpha: 0.9 * mAlpha * math.min(1, g),
              )
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.07),
          );
          canvas.drawCircle(
            const Offset(0, 0.165),
            0.34,
            Paint()
              ..shader = ui.Gradient.radial(const Offset(0, 0.165), 0.34, [
                _gold.withValues(alpha: 0.24 * mAlpha * math.min(1.5, g)),
                _gold.withValues(alpha: 0),
              ]),
          );
        }
        canvas.drawRRect(
          c,
          Paint()..color = Colors.white.withValues(alpha: mAlpha),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(EmblemPainter old) =>
      old.glow != glow ||
      old.draw != draw ||
      old.detail != detail ||
      old.style != style ||
      old.scale != scale;
}

/// Launcher-icon background: warm charcoal radial field, faint hex lattice and
/// a soft top light. Shared with the icon renderer.
class IconBackgroundPainter extends CustomPainter {
  const IconBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final c = r.center;
    canvas.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(c.dx, size.height * 0.42),
          size.width * 0.75,
          const [Color(0xFF2A1517), Color(0xFF141214), Color(0xFF0A0A0C)],
          const [0, 0.55, 1],
        ),
    );
    // Hex lattice.
    final hexR = size.width / 14;
    final w = math.sqrt(3) * hexR;
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width / 900
      ..shader = ui.Gradient.radial(
        Offset(c.dx, size.height * 0.45),
        size.width * 0.7,
        [
          AppColors.red.withValues(alpha: 0.12),
          AppColors.red.withValues(alpha: 0.0),
        ],
      );
    final path = Path();
    for (var row = -1; row * hexR * 1.5 < size.height + hexR; row++) {
      final y = row * hexR * 1.5;
      final off = row.isOdd ? w / 2 : 0.0;
      for (var x = -w + off; x < size.width + w; x += w) {
        final pts = EmblemPainter.hex(hexR).map((p) => p + Offset(x, y));
        path.addPolygon(pts.toList(), true);
      }
    }
    canvas.drawPath(path, grid);
    // Top light.
    canvas.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(c.dx, -size.height * 0.1),
          size.width * 0.9,
          [
            AppColors.gold.withValues(alpha: 0.08),
            AppColors.gold.withValues(alpha: 0.0),
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(IconBackgroundPainter oldDelegate) => false;
}
