import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/mood_stats.dart';
import 'life_widgets.dart';

/// Emotive mood reactor: a luminous sphere in a HUD bezel whose minimal face
/// (two eyes, one mouth line) morphs continuously between the five mood
/// states. `mood == null` is the honest "standby" state (no check-in yet):
/// a dim, level face in a dashed bezel.
///
/// Mood changes spring between states; large orbs breathe slowly.
/// Respects reduced motion (no breathing, instant morph).
class MoodOrb extends StatefulWidget {
  const MoodOrb({
    super.key,
    required this.mood,
    this.size = 120,
    this.breathe,
    this.semanticLabel,
    this.bezel = true,
  });

  /// 1..5 (fractional allowed, e.g. a daily mean) or null for standby.
  final double? mood;
  final double size;

  /// Slow idle breathing (defaults to on for orbs ≥ 96 px).
  final bool? breathe;
  final String? semanticLabel;

  /// Outer tick bezel (auto-off below 48 px).
  final bool bezel;

  @override
  State<MoodOrb> createState() => _MoodOrbState();
}

class _MoodOrbState extends State<MoodOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );

  bool get _wantsBreath => widget.breathe ?? widget.size >= 96;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBreath();
  }

  @override
  void didUpdateWidget(MoodOrb old) {
    super.didUpdateWidget(old);
    _syncBreath();
  }

  void _syncBreath() {
    final on =
        _wantsBreath &&
        !AppMotion.reduced(context) &&
        !RuntimeEnv.isFlutterTest;
    if (on && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!on && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    final m = widget.mood;
    final label =
        widget.semanticLabel ??
        (m == null
            ? 'No mood check-in yet'
            : 'Mood ${moodLabels[m.round().clamp(1, 5)]}');
    return Semantics(
      label: label,
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: m ?? 0),
          duration: reduced ? Duration.zero : const Duration(milliseconds: 650),
          curve: SpringCurve(AppMotion.bouncy),
          builder: (context, v, _) => AnimatedBuilder(
            animation: _breath,
            builder: (context, _) => CustomPaint(
              painter: MoodOrbPainter(
                mood: v,
                standby: m == null,
                breath: Curves.easeInOut.transform(_breath.value),
                hud: hud,
                bezel: widget.bezel && widget.size >= 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MoodOrbPainter extends CustomPainter {
  MoodOrbPainter({
    required this.mood,
    required this.standby,
    required this.breath,
    required this.hud,
    required this.bezel,
  });

  /// 1..5 (0 while animating up from standby is treated as 3).
  final double mood;
  final bool standby;
  final double breath;
  final HudTheme hud;
  final bool bezel;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final m = mood <= 0 ? 3.0 : mood.clamp(1.0, 5.0);
    final valence = standby ? 0.0 : (m - 3) / 2; // -1..1
    final base = standby ? hud.textMuted : moodColorAt(m);
    final glow = hud.glowStrength;
    final r = s * (bezel ? 0.34 : 0.44) * (1 + 0.025 * breath);

    // Bezel: tick ring + thin arc (dashed in standby).
    if (bezel) {
      final ringR = s * 0.47;
      final tick = Paint()
        ..color = base.withValues(alpha: standby ? 0.25 : 0.4)
        ..strokeWidth = math.max(1, s * 0.008)
        ..strokeCap = StrokeCap.round;
      const n = 48;
      for (var i = 0; i < n; i++) {
        final a = -math.pi / 2 + i / n * math.pi * 2;
        final major = i % 6 == 0;
        final len = s * (major ? 0.04 : 0.02);
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(
          c + dir * ringR,
          c + dir * (ringR - len),
          tick
            ..color = base.withValues(
              alpha: (standby ? 0.18 : 0.3) + (major ? 0.2 : 0),
            ),
        );
      }
      final arcR = s * 0.405;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.012)
        ..strokeCap = StrokeCap.round
        ..color = base.withValues(alpha: standby ? 0.3 : 0.75);
      if (standby) {
        for (var i = 0; i < 24; i++) {
          final a0 = i / 24 * math.pi * 2;
          canvas.drawArc(
            Rect.fromCircle(center: c, radius: arcR),
            a0,
            math.pi * 2 / 24 * 0.5,
            false,
            arcPaint,
          );
        }
      } else {
        // The arc fills with the mood level (1 → 20 %, 5 → 100 %).
        final sweep = (m / 5) * math.pi * 2;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: arcR),
          -math.pi / 2,
          math.pi * 2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = arcPaint.strokeWidth
            ..color = base.withValues(alpha: 0.12),
        );
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: arcR),
          -math.pi / 2,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = arcPaint.strokeWidth * 1.6
            ..strokeCap = StrokeCap.round
            ..color = base.withValues(alpha: 0.5 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.02),
        );
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: arcR),
          -math.pi / 2,
          sweep,
          false,
          arcPaint,
        );
      }
    }

    // Outer bloom.
    canvas.drawCircle(
      c,
      r * 1.45,
      Paint()
        ..shader = RadialGradient(
          colors: [
            base.withValues(alpha: (standby ? 0.10 : 0.30) * glow),
            base.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 1.45)),
    );

    // Sphere body: lit from the top-left like the rest of the HUD.
    final body = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: standby
              ? [
                  base.withValues(alpha: hud.isDark ? 0.22 : 0.18),
                  base.withValues(alpha: hud.isDark ? 0.08 : 0.06),
                ]
              : [
                  Color.lerp(base, Colors.white, 0.35)!.withValues(alpha: 0.95),
                  base.withValues(alpha: 0.75),
                  Color.lerp(base, Colors.black, 0.45)!.withValues(alpha: 0.85),
                ],
        ).createShader(body),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.008)
        ..color = Color.lerp(
          base,
          Colors.white,
          0.5,
        )!.withValues(alpha: standby ? 0.25 : 0.55),
    );
    // Specular glint.
    if (!standby) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c + Offset(-r * 0.36, -r * 0.48),
          width: r * 0.55,
          height: r * 0.26,
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.28),
      );
    }

    // Face.
    final ink = standby
        ? hud.textMuted.withValues(alpha: 0.8)
        : const Color(0xFF0B1220).withValues(alpha: 0.82);
    final stroke = math.max(1.4, r * 0.085);
    final eyeY = c.dy - r * 0.16;
    final eyeDx = r * 0.32;
    // Eyes: round dots that squint into happy arcs as valence rises, and
    // soften (lowered lids) as it falls.
    for (final sx in const [-1.0, 1.0]) {
      final e = Offset(c.dx + sx * eyeDx, eyeY);
      final happy = valence.clamp(0.0, 1.0);
      final sad = (-valence).clamp(0.0, 1.0);
      if (happy > 0.55) {
        final t = (happy - 0.55) / 0.45;
        final w = r * 0.2;
        final p = Path()
          ..moveTo(e.dx - w / 2, e.dy + r * 0.03)
          ..quadraticBezierTo(
            e.dx,
            e.dy - r * (0.05 + 0.1 * t),
            e.dx + w / 2,
            e.dy + r * 0.03,
          );
        canvas.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..color = ink,
        );
      } else {
        final h = r * (0.16 - 0.06 * sad - 0.08 * (happy / 0.55) * 0.5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: e, width: r * 0.11, height: h),
            Radius.circular(r * 0.06),
          ),
          Paint()..color = ink,
        );
        if (sad > 0.2) {
          // A gentle, slanted lid — tired, not dramatic.
          final lid = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 0.8
            ..strokeCap = StrokeCap.round
            ..color = ink.withValues(alpha: 0.85 * sad);
          canvas.drawLine(
            Offset(e.dx - r * 0.09, e.dy - r * 0.12 + sx * r * 0.0),
            Offset(e.dx + r * 0.09, e.dy - r * 0.12 - sx * r * 0.035 * sad),
            lid,
          );
        }
      }
    }
    // Mouth: a curve whose bend follows valence; width grows when happy.
    final mouthY = c.dy + r * 0.3;
    final mw = r * (0.42 + 0.12 * valence.clamp(0.0, 1.0));
    final bend = r * 0.24 * valence;
    final mouth = Path()
      ..moveTo(c.dx - mw / 2, mouthY - bend * 0.25)
      ..quadraticBezierTo(
        c.dx,
        mouthY + bend,
        c.dx + mw / 2,
        mouthY - bend * 0.25,
      );
    canvas.drawPath(
      mouth,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = ink,
    );
  }

  @override
  bool shouldRepaint(MoodOrbPainter old) =>
      old.mood != mood ||
      old.standby != standby ||
      old.breath != breath ||
      old.hud != hud ||
      old.bezel != bezel;
}

/// One of the five mood choices: a small orb + label that lifts and glows
/// when selected.
class MoodFaceButton extends StatelessWidget {
  const MoodFaceButton({
    super.key,
    required this.mood,
    required this.selected,
    required this.onTap,
    this.size = 44,
    this.showLabel = true,
  });

  final int mood;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = moodColor(mood);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Mood ${moodLabels[mood]}',
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.9,
        child: AnimatedContainer(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: c.withValues(alpha: selected ? 0.14 : 0),
            border: Border.all(
              color: selected ? c.withValues(alpha: 0.7) : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: selected ? 1.12 : 1,
                duration: AppMotion.medium,
                curve: SpringCurve(AppMotion.bouncy),
                child: MoodOrb(
                  mood: mood.toDouble(),
                  size: size,
                  bezel: false,
                  breathe: false,
                ),
              ),
              if (showLabel) ...[
                const SizedBox(height: 6),
                Text(
                  moodLabels[mood]!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? hud.text : hud.textMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Five mood buttons in a row.
class MoodPicker extends StatelessWidget {
  const MoodPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 40,
    this.showLabels = true,
  });

  final int? value;
  final ValueChanged<int> onChanged;
  final double size;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var m = 1; m <= 5; m++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: MoodFaceButton(
                key: Key('mood-$m'),
                mood: m,
                size: size,
                selected: value == m,
                showLabel: showLabels,
                onTap: () => onChanged(m),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact "ENERGY ▮▮▮▯▯" readout used on check-in summaries.
class MiniLevel extends StatelessWidget {
  const MiniLevel({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.valueLabel,
  });

  final String label;
  final int? value;
  final Color color;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final v = value ?? 0;
    return Semantics(
      label: '$label: ${valueLabel ?? (value == null ? 'not set' : '$v of 5')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: hud.label(size: 10)),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= 5; i++)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 2.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1.5),
                    color: i <= v
                        ? color.withValues(alpha: 0.45 + 0.11 * i)
                        : hud.hairline.withValues(
                            alpha: hud.isDark ? 0.1 : 0.18,
                          ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mood colour of the five-step scale used by charts (Very low → Great).
const moodScaleColors = [
  Color(0xFF94A3B8),
  Color(0xFF7DD3FC),
  Color(0xFFA5B4FC),
  Color(0xFF86EFAC),
  AppColors.mood,
];
