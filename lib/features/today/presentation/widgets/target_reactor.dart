import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// One ring of the [TargetReactor].
class TargetRingData {
  const TargetRingData({
    required this.id,
    required this.label,
    required this.unit,
    required this.color,
    required this.icon,
    required this.value,
    required this.target,
    required this.valueText,
    required this.targetText,
    required this.statusText,
    this.missingText = 'NOT SYNCED',
    this.detail,
  });

  final String id;

  /// Short HUD label, e.g. "STEPS".
  final String label;

  /// Unit shown under the centre readout, e.g. "KCAL".
  final String unit;
  final Color color;
  final IconData icon;

  /// Null = no data (not synced). Zero is a real "nothing logged yet".
  final double? value;
  final double target;
  final String valueText;
  final String targetText;

  /// "1,850 to go", "Goal reached"…
  final String statusText;
  final String missingText;

  /// Expanded panel shown when the ring is selected.
  final Widget? detail;

  bool get available => value != null;
  double get progress =>
      value == null || target <= 0 ? 0 : (value! / target).clamp(0.0, 1.0);
  bool get reached => value != null && target > 0 && value! >= target;
}

/// The Today hero: concentric arc-reactor rings for the day's targets with a
/// legend. Tap a ring (or its legend row) to expand its detail panel. Rings
/// without data show the target only, as dashed "standby" rings.
class TargetReactor extends StatefulWidget {
  const TargetReactor({super.key, required this.rings, this.size = 150});

  final List<TargetRingData> rings;
  final double size;

  @override
  State<TargetReactor> createState() => _TargetReactorState();
}

class _TargetReactorState extends State<TargetReactor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  final _burst = CelebrationController();
  late List<double> _from = List.filled(widget.rings.length, 0);
  late List<double> _to = [for (final r in widget.rings) r.progress];
  String? _selected;
  bool _celebratePending = false;
  Color _burstColor = AppColors.gold;

  @override
  void initState() {
    super.initState();
    _sweep.addStatusListener((s) {
      if (s == AnimationStatus.completed && _celebratePending) {
        _celebratePending = false;
        _burst.fire();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sweep.status == AnimationStatus.dismissed) {
      if (AppMotion.reduced(context)) {
        _sweep.value = 1;
      } else {
        _sweep.forward();
      }
    }
  }

  @override
  void didUpdateWidget(TargetReactor old) {
    super.didUpdateWidget(old);
    final next = [for (final r in widget.rings) r.progress];
    if (next.length != _to.length || !_listEq(next, _to)) {
      final current = _current();
      for (var i = 0; i < widget.rings.length && i < old.rings.length; i++) {
        if (!old.rings[i].reached && widget.rings[i].reached) {
          _celebratePending = true;
          _burstColor = widget.rings[i].color;
          Haptics.goalReached();
        }
      }
      _from = current.length == next.length
          ? current
          : List.filled(next.length, 0);
      _to = next;
      if (AppMotion.reduced(context)) {
        _sweep.value = 1;
        if (_celebratePending) {
          _celebratePending = false;
          _burst.fire();
        }
      } else {
        _sweep.forward(from: 0);
      }
    }
  }

  static bool _listEq(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1e-6) return false;
    }
    return true;
  }

  List<double> _current() {
    final n = _to.length;
    return [for (var i = 0; i < n; i++) _valueAt(i)];
  }

  double _valueAt(int i) {
    final start = (i * 0.09).clamp(0.0, 0.5);
    final local = ((_sweep.value - start) / (1 - start)).clamp(0.0, 1.0);
    final e = AppMotion.emphasizedDecelerate.transform(local);
    final from = i < _from.length ? _from[i] : 0.0;
    return from + (_to[i] - from) * e;
  }

  @override
  void dispose() {
    _sweep.dispose();
    _burst.dispose();
    super.dispose();
  }

  void _select(String? id) {
    Haptics.selection();
    setState(() => _selected = _selected == id ? null : id);
  }

  int? _ringAt(Offset local) {
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = (local - c).distance;
    final geo = _ReactorGeometry(widget.size, widget.rings.length);
    if (d < geo.coreRadius) return -1;
    for (var i = 0; i < widget.rings.length; i++) {
      if ((d - geo.radius(i)).abs() <= geo.stroke / 2 + geo.gap / 2 + 1) {
        return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final rings = widget.rings;
    final selected = rings.where((r) => r.id == _selected).firstOrNull;
    final available = rings.where((r) => r.available).toList();
    final composite = available.isEmpty
        ? null
        : available.fold<double>(0, (s, r) => s + r.progress) /
              available.length;

    final reactor = SizedBox.square(
      dimension: widget.size,
      child: CelebrationBurst(
        controller: _burst,
        color: _burstColor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Ring taps mirror the legend rows, which carry the semantics.
          excludeFromSemantics: true,
          onTapUp: (d) {
            final i = _ringAt(d.localPosition);
            if (i == null) return;
            _select(i < 0 ? null : rings[i].id);
          },
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => CustomPaint(
                painter: _ConcentricReactorPainter(
                  rings: rings,
                  values: [for (var i = 0; i < rings.length; i++) _valueAt(i)],
                  selected: _selected,
                  hud: hud,
                ),
                child: Center(
                  // Keep the readout inside the core disc (it used to touch
                  // the innermost ring at larger text sizes).
                  child: SizedBox(
                    width:
                        _ReactorGeometry(widget.size, rings.length).coreRadius *
                        1.5,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _CenterReadout(
                        selected: selected,
                        composite: composite,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final legend = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rings)
          _LegendRow(
            ring: r,
            selected: r.id == _selected,
            dimmed: _selected != null && r.id != _selected,
            onTap: () => _select(r.id),
          ),
      ],
    );

    return AppCard(
      brackets: true,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md + 2,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('DAILY TARGETS', style: hud.label(size: 12)),
              const Spacer(),
              AnimatedSwitcher(
                duration: AppMotion.short,
                child: Text(
                  _selected == null ? 'TAP A RING' : 'TAP CORE TO RESET',
                  key: ValueKey(_selected == null),
                  style: hud.mono(
                    size: 9.5,
                    color: hud.textMuted.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, box) {
              final stack =
                  box.maxWidth < widget.size + 140 ||
                  MediaQuery.textScalerOf(context).scale(10) > 11.5;
              if (stack) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: reactor),
                    const SizedBox(height: AppSpacing.md),
                    legend,
                  ],
                );
              }
              return Row(
                children: [
                  reactor,
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(child: legend),
                ],
              );
            },
          ),
          AnimatedSize(
            duration: AppMotion.medium,
            curve: AppMotion.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: selected?.detail == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    key: ValueKey(selected!.id),
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Entrance(
                      offset: const Offset(0, 8),
                      duration: AppMotion.medium,
                      child: _DetailFrame(
                        color: selected.color,
                        child: DefaultTextStyle.merge(
                          style: t.bodyMedium,
                          child: selected.detail!,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetailFrame extends StatelessWidget {
  const _DetailFrame({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: hud.isDark ? 0.12 : 0.10),
            color.withValues(alpha: 0.02),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: child,
    );
  }
}

class _CenterReadout extends StatelessWidget {
  const _CenterReadout({required this.selected, required this.composite});
  final TargetRingData? selected;
  final double? composite;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final s = selected;
    final String big;
    final String small;
    Color color = hud.text;
    if (s != null) {
      big = s.available ? s.valueText : '—';
      small = s.unit;
      color = s.reached ? AppColors.gold : hud.text;
    } else if (composite == null) {
      big = '—';
      small = 'STANDBY';
    } else {
      big = '${(composite! * 100).round()}%';
      small = 'OVERALL';
      if (composite! >= 0.999) color = AppColors.gold;
    }
    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: AppMotion.short,
        child: Column(
          key: ValueKey('${s?.id}-$small'),
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              child: AnimatedTicker(
                big,
                style: hud.number(size: 22, color: color),
              ),
            ),
            const SizedBox(height: 2),
            Text(small, style: hud.label(size: 8.5)),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.ring,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final TargetRingData ring;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final r = ring;
    final statusColor = !r.available
        ? hud.textMuted
        : r.reached
        ? (hud.isDark ? AppColors.gold : AppColors.goldInk)
        : hud.textMuted;
    final semantics = r.available
        ? '${r.label.toLowerCase()}: ${r.valueText} of ${r.targetText}, '
              '${r.statusText}'
        : '${r.label.toLowerCase()}: ${r.missingText.toLowerCase()}, '
              'target ${r.targetText}';
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.none,
        pressedScale: 0.97,
        child: AnimatedOpacity(
          duration: AppMotion.short,
          opacity: dimmed ? 0.45 : 1,
          child: AnimatedContainer(
            duration: AppMotion.short,
            margin: const EdgeInsets.symmetric(vertical: 1),
            constraints: const BoxConstraints(
              minHeight: AppSpacing.touchTarget,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.xs + 2),
              color: selected
                  ? r.color.withValues(alpha: 0.10)
                  : Colors.transparent,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 26,
                  margin: const EdgeInsets.only(right: 8, top: 1),
                  decoration: BoxDecoration(
                    color: r.available ? r.color : null,
                    border: r.available
                        ? null
                        : Border.all(color: r.color.withValues(alpha: 0.55)),
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: r.available
                        ? [
                            BoxShadow(
                              color: r.color.withValues(
                                alpha: 0.6 * hud.glowStrength,
                              ),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(r.label, style: hud.label(size: 10.5)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              r.available ? r.statusText : r.missingText,
                              style: r.available
                                  ? t.labelSmall?.copyWith(color: statusColor)
                                  : hud.mono(size: 9, color: statusColor),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            if (r.available)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                child: AnimatedTicker(
                                  r.valueText,
                                  style: t.titleSmall?.copyWith(
                                    fontFamily: AppFonts.display,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            TextSpan(
                              text: r.available
                                  ? ' / ${r.targetText}'
                                  : 'Target ${r.targetText}',
                              style: t.labelSmall?.copyWith(
                                color: hud.textMuted,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactorGeometry {
  _ReactorGeometry(this.size, this.count)
    : stroke = size * 0.047,
      gap = size * 0.025;
  final double size;
  final int count;
  final double stroke;
  final double gap;

  double get outer => size / 2;
  double get bezel => size * 0.03;
  double radius(int i) => outer - bezel - 4 - stroke / 2 - i * (stroke + gap);
  double get coreRadius => radius(count - 1) - stroke / 2 - 2;
}

class _ConcentricReactorPainter extends CustomPainter {
  _ConcentricReactorPainter({
    required this.rings,
    required this.values,
    required this.selected,
    required this.hud,
  });

  final List<TargetRingData> rings;
  final List<double> values;
  final String? selected;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final geo = _ReactorGeometry(size.shortestSide, rings.length);
    final g = hud.glowStrength;
    const start = -math.pi / 2;

    // Core glow (the arc reactor's heart).
    final core = geo.coreRadius;
    canvas.drawCircle(
      c,
      core,
      Paint()
        ..shader = RadialGradient(
          colors: [
            hud.accent.withValues(alpha: 0.16 * (hud.isDark ? 1 : 0.6)),
            hud.accent.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: core)),
    );
    canvas.drawCircle(
      c,
      core,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hud.accent.withValues(alpha: 0.28),
    );

    // Outer bezel: 72 ticks, majors every 6.
    final dim = Paint()
      ..color = hud.text.withValues(alpha: hud.isDark ? 0.16 : 0.2)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = hud.accent.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;
    const n = 72;
    for (var i = 0; i < n; i++) {
      final a = start + i * 2 * math.pi / n;
      final isMajor = i % 6 == 0;
      final r1 = geo.outer - 0.5;
      final r0 = r1 - (isMajor ? geo.bezel : geo.bezel * 0.5);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * r0, c + dir * r1, isMajor ? major : dim);
    }

    for (var i = 0; i < rings.length; i++) {
      final ring = rings[i];
      final r = geo.radius(i);
      final rect = Rect.fromCircle(center: c, radius: r);
      final emphasis = selected == null || selected == ring.id ? 1.0 : 0.35;
      final color = ring.color;

      if (!ring.available) {
        // Standby: dashed hairline + quarter target ticks, no fake value.
        final dash = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = color.withValues(alpha: 0.45 * emphasis);
        const dashes = 48;
        for (var k = 0; k < dashes; k++) {
          final a0 = start + k * 2 * math.pi / dashes;
          canvas.drawArc(rect, a0, 2 * math.pi / dashes * 0.45, false, dash);
        }
        final tick = Paint()
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: 0.7 * emphasis);
        for (var q = 0; q < 4; q++) {
          final a = start + q * math.pi / 2;
          final dir = Offset(math.cos(a), math.sin(a));
          canvas.drawLine(
            c + dir * (r - geo.stroke / 2),
            c + dir * (r + geo.stroke / 2),
            tick,
          );
        }
        continue;
      }

      // Segmented track.
      const segments = 48;
      const gapRad = 0.05;
      final track = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geo.stroke * 0.55
        ..color = color.withValues(
          alpha: (hud.isDark ? 0.16 : 0.2) * (0.5 + 0.5 * emphasis),
        );
      for (var k = 0; k < segments; k++) {
        final a0 = start + k * 2 * math.pi / segments + gapRad / 2;
        canvas.drawArc(rect, a0, 2 * math.pi / segments - gapRad, false, track);
      }

      final v = values[i].clamp(0.0, 1.0);
      if (v <= 0.001) continue;
      final sweep = 2 * math.pi * v;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = geo.stroke
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.4 * g * emphasis)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, geo.stroke * 0.7),
      );
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = geo.stroke
          ..strokeCap = StrokeCap.butt
          ..shader = SweepGradient(
            colors: [
              color.withValues(alpha: 0.45 * emphasis),
              color.withValues(alpha: emphasis),
            ],
            stops: [0, math.max(0.001, v)],
            transform: const GradientRotation(start),
          ).createShader(rect),
      );
      final head =
          c + Offset(math.cos(start + sweep), math.sin(start + sweep)) * r;
      canvas.drawCircle(
        head,
        geo.stroke * 0.32,
        Paint()
          ..color = Color.lerp(
            color,
            Colors.white,
            0.75,
          )!.withValues(alpha: emphasis),
      );
    }
  }

  @override
  bool shouldRepaint(_ConcentricReactorPainter old) =>
      old.selected != selected ||
      old.hud != hud ||
      old.rings != rings ||
      !_eq(old.values, values);

  static bool _eq(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
