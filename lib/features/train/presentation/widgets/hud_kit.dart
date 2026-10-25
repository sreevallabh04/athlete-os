import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// Feature-level HUD building blocks shared by the Train, Health and
/// Integrations screens: interactive charts (scrub with selection haptics),
/// readouts, pressable rows, status dots and numbered setup steps.
///
/// Everything composes the core design system (`HudChartStyle`,
/// `PressableScale`, `Haptics`, `AnimatedTicker`); nothing here paints its
/// own theme.

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

/// Interactive HUD line chart. Values are plotted by index; drag across the
/// chart to scrub (frosted tooltip + a selection haptic per point).
///
/// * [invert]: lower is better (pace); faster values are drawn higher and the
///   axis labels stay in real units.
/// * [reference]: dashed goal line (e.g. 6:00 /km).
/// * [gold]: indexes drawn as gold nodes (PRs).
/// * Draws in from the baseline on first build (skipped with reduced motion).
class HudLineChart extends StatefulWidget {
  const HudLineChart({
    super.key,
    required this.values,
    required this.color,
    required this.semanticLabel,
    required this.format,
    this.xLabel,
    this.tooltip,
    this.height = 180,
    this.invert = false,
    this.reference,
    this.referenceLabel,
    this.gold = const {},
    this.curved = true,
    this.onScrub,
    this.leftReserved = 40,
    this.rollingWindow,
    this.rollingLabel = 'avg',
  });

  final List<double> values;
  final Color color;
  final String semanticLabel;
  final String Function(double v) format;
  final String Function(int i)? xLabel;
  final String Function(int i)? tooltip;
  final double height;
  final bool invert;
  final double? reference;
  final String? referenceLabel;
  final Set<int> gold;
  final bool curved;
  final ValueChanged<int?>? onScrub;
  final double leftReserved;

  /// When set, raw values are drawn as faint dots and a trailing moving
  /// average over this many points is the bold line (separates the signal
  /// from mixed easy/hard sessions).
  final int? rollingWindow;
  final String rollingLabel;

  @override
  State<HudLineChart> createState() => _HudLineChartState();
}

class _HudLineChartState extends State<HudLineChart> {
  bool _revealed = false;
  int? _scrub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _revealed = true);
    });
  }

  double _p(double v) => widget.invert ? -v : v;

  void _onTouch(FlTouchEvent event, LineTouchResponse? r) {
    final idx = event.isInterestedForInteractions
        ? r?.lineBarSpots?.firstOrNull?.spotIndex
        : null;
    if (idx == _scrub) return;
    _scrub = idx;
    if (idx != null) Haptics.selection();
    widget.onScrub?.call(idx);
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final values = widget.values;
    if (values.isEmpty) return SizedBox(height: widget.height);
    final reduced = AppMotion.reduced(context);
    final ys = [
      for (final v in values) _p(v),
      if (widget.reference != null) _p(widget.reference!),
    ];
    var lo = ys.reduce(math.min);
    var hi = ys.reduce(math.max);
    if ((hi - lo).abs() < 1e-6) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.18;
    final minY = lo - pad;
    final maxY = hi + pad;
    final show = _revealed || reduced;
    final spots = [
      for (var i = 0; i < values.length; i++)
        FlSpot(i.toDouble(), show ? _p(values[i]) : minY),
    ];
    final rolling = widget.rollingWindow;
    final bar = HudChartStyle.line(
      spots,
      rolling == null ? widget.color : widget.color.withValues(alpha: 0.4),
      curved: widget.curved && rolling == null,
      fill: rolling == null,
      width: rolling == null ? 2.5 : 1.2,
    );
    final avg = <FlSpot>[];
    if (rolling != null) {
      for (var i = 0; i < values.length; i++) {
        final from = math.max(0, i - rolling + 1);
        final win = values.sublist(from, i + 1);
        final m = win.reduce((a, b) => a + b) / win.length;
        avg.add(FlSpot(i.toDouble(), show ? _p(m) : minY));
      }
    }
    final last = values.length - 1;
    final styled = bar.copyWith(
      dotData: FlDotData(
        checkToShowDot: (s, _) =>
            widget.gold.contains(s.x.round()) ||
            s.x.round() == last ||
            rolling != null,
        getDotPainter: (s, _, _, _) {
          final isGold = widget.gold.contains(s.x.round());
          final c = isGold ? AppColors.gold : widget.color;
          if (rolling != null && !isGold) {
            return FlDotCirclePainter(
              radius: 2.6,
              color: widget.color.withValues(alpha: 0.75),
              strokeWidth: 0,
              strokeColor: Colors.transparent,
            );
          }
          return FlDotCirclePainter(
            radius: isGold ? 3.6 : 4,
            color: Color.lerp(c, Colors.white, isGold ? 0.25 : 0.7)!,
            strokeWidth: 2,
            strokeColor: c,
          );
        },
      ),
    );
    final labelStyle = HudChartStyle.axisLabel(context);
    final n = values.length;
    final xInterval = math.max(1, (n / 4).ceil()).toDouble();
    return Semantics(
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        height: widget.height,
        child: LineChart(
          duration: reduced ? Duration.zero : AppMotion.data,
          curve: AppMotion.emphasizedDecelerate,
          LineChartData(
            minY: minY,
            maxY: maxY,
            minX: 0,
            maxX: math.max(1, n - 1).toDouble(),
            gridData: HudChartStyle.grid(context, interval: (maxY - minY) / 3),
            borderData: HudChartStyle.noBorder,
            clipData: const FlClipData.horizontal(),
            titlesData: HudChartStyle.titles(
              context,
              leftReserved: widget.leftReserved,
              leftInterval: (maxY - minY) / 3,
              bottomInterval: xInterval,
              left: (v, meta) {
                if (v <= meta.min + 1e-9 || v >= meta.max - 1e-9) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    widget.format(widget.invert ? -v : v),
                    style: labelStyle,
                  ),
                );
              },
              bottom: widget.xLabel == null
                  ? null
                  : (v, meta) {
                      final i = v.round();
                      if ((v - i).abs() > 1e-6 ||
                          i < 0 ||
                          i >= n ||
                          i % xInterval.round() != 0) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        child: Text(widget.xLabel!(i), style: labelStyle),
                      );
                    },
            ),
            extraLinesData: widget.reference == null
                ? const ExtraLinesData()
                : ExtraLinesData(
                    horizontalLines: [
                      HorizontalLine(
                        y: _p(widget.reference!),
                        color: AppColors.gold.withValues(alpha: 0.7),
                        strokeWidth: 1.2,
                        dashArray: const [5, 4],
                        label: HorizontalLineLabel(
                          show: widget.referenceLabel != null,
                          alignment: Alignment.topRight,
                          padding: const EdgeInsets.only(right: 2, bottom: 3),
                          style: hud
                              .mono(size: 10, color: AppColors.gold)
                              .copyWith(fontWeight: FontWeight.w600),
                          labelResolver: (_) => widget.referenceLabel ?? '',
                        ),
                      ),
                    ],
                  ),
            lineTouchData: HudChartStyle.lineTouch(
              context,
              format: (s) => s.barIndex == 1
                  ? '${widget.rollingLabel} '
                        '${widget.format(widget.invert ? -s.y : s.y)}'
                  : widget.tooltip?.call(s.spotIndex) ??
                        widget.format(values[s.spotIndex]),
            ).copyWith(touchCallback: _onTouch),
            lineBarsData: [
              styled,
              if (rolling != null)
                HudChartStyle.line(avg, widget.color, width: 2.8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Interactive HUD bar chart. `null` values are "no data" and drawn as a
/// faint baseline tick, never as a measured zero.
class HudBarChart extends StatefulWidget {
  const HudBarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.color,
    required this.semanticLabel,
    required this.tooltip,
    this.height = 170,
    this.goal,
    this.goalLabel,
    this.highlight,
    this.colorFor,
    this.onSelect,
    this.barWidth,
    this.minY,
  });

  final List<double?> values;

  /// Bottom labels; empty strings are skipped.
  final List<String> labels;
  final Color color;
  final String semanticLabel;
  final String Function(int i, double? v) tooltip;
  final double height;
  final double? goal;
  final String? goalLabel;

  /// Index drawn at full intensity (e.g. today / this week).
  final int? highlight;

  /// Per-bar colour override.
  final Color Function(int i, double v)? colorFor;
  final ValueChanged<int?>? onSelect;
  final double? barWidth;
  final double? minY;

  @override
  State<HudBarChart> createState() => _HudBarChartState();
}

class _HudBarChartState extends State<HudBarChart> {
  bool _revealed = false;
  int? _sel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _revealed = true);
    });
  }

  void _onTouch(FlTouchEvent event, BarTouchResponse? r) {
    final idx = event.isInterestedForInteractions
        ? r?.spot?.touchedBarGroupIndex
        : null;
    if (idx == _sel) return;
    _sel = idx;
    if (idx != null) Haptics.selection();
    widget.onSelect?.call(idx);
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    final show = _revealed || reduced;
    final vals = widget.values;
    final n = vals.length;
    final maxVal = vals.fold<double>(0, (m, v) => math.max(m, v ?? 0));
    final top = math.max(maxVal, widget.goal ?? 0);
    final minY = widget.minY ?? 0;
    final maxY = top <= 0 ? 1.0 : top + (top - minY) * 0.18;
    final w = widget.barWidth ?? (n > 14 ? 6.0 : (n > 8 ? 12.0 : 16.0));
    final labelStyle = HudChartStyle.axisLabel(context);
    return Semantics(
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        height: widget.height,
        child: BarChart(
          duration: reduced ? Duration.zero : AppMotion.data,
          curve: AppMotion.emphasizedDecelerate,
          BarChartData(
            maxY: maxY,
            minY: minY,
            alignment: BarChartAlignment.spaceAround,
            gridData: HudChartStyle.grid(context, interval: (maxY - minY) / 3),
            borderData: HudChartStyle.noBorder,
            titlesData: HudChartStyle.titles(
              context,
              bottom: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= widget.labels.length) {
                  return const SizedBox.shrink();
                }
                final label = widget.labels[i];
                if (label.isEmpty) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    label,
                    style: i == widget.highlight
                        ? labelStyle.copyWith(color: hud.accentInk)
                        : labelStyle,
                  ),
                );
              },
            ),
            extraLinesData: widget.goal == null || widget.goal! <= 0
                ? const ExtraLinesData()
                : ExtraLinesData(
                    horizontalLines: [
                      HorizontalLine(
                        y: widget.goal!,
                        color: AppColors.gold.withValues(alpha: 0.65),
                        strokeWidth: 1.2,
                        dashArray: const [5, 4],
                        label: HorizontalLineLabel(
                          show: widget.goalLabel != null,
                          alignment: Alignment.topRight,
                          padding: const EdgeInsets.only(right: 2, bottom: 3),
                          style: hud
                              .mono(size: 10, color: AppColors.gold)
                              .copyWith(fontWeight: FontWeight.w600),
                          labelResolver: (_) => widget.goalLabel ?? '',
                        ),
                      ),
                    ],
                  ),
            barTouchData: HudChartStyle.barTouch(
              context,
              format: (g, _) => widget.tooltip(g.x, vals[g.x]),
            ).copyWith(touchCallback: _onTouch),
            barGroups: [
              for (var i = 0; i < n; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    if (vals[i] == null)
                      BarChartRodData(
                        toY: minY + (maxY - minY) * 0.015,
                        width: w,
                        color: hud.textMuted.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(1),
                      )
                    else
                      HudChartStyle.rod(
                        show ? vals[i]! : 0,
                        _barColor(i, vals[i]!),
                        width: w,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _barColor(int i, double v) {
    final custom = widget.colorFor?.call(i, v);
    if (custom != null) return custom;
    final hit = widget.goal != null && widget.goal! > 0 && v >= widget.goal!;
    if (i == widget.highlight || hit) return widget.color;
    return widget.color.withValues(alpha: 0.62);
  }
}

// ---------------------------------------------------------------------------
// Readouts & labels
// ---------------------------------------------------------------------------

/// HUD label + big ticking number + unit + caption.
class HudReadout extends StatelessWidget {
  const HudReadout({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.caption,
    this.color,
    this.size = 34,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final String label;
  final String value;
  final String? unit;
  final String? caption;
  final Color? color;
  final double size;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      label:
          '$label: $value${unit == null ? '' : ' $unit'}'
          '${caption == null ? '' : ', $caption'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: crossAxisAlignment,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: hud.label(size: 11)),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              AnimatedTicker(
                value,
                style: hud.number(size: size, color: color ?? hud.text),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit!, style: hud.label(size: 12)),
              ],
            ],
          ),
          if (caption != null)
            Text(
              caption!,
              style: t.bodySmall?.copyWith(color: hud.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// Tiny mono tag, e.g. `EST.` or `RULE-BASED`.
class HudTag extends StatelessWidget {
  const HudTag(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.45)),
        color: c.withValues(alpha: 0.08),
      ),
      child: Text(
        text,
        style: hud
            .mono(size: 9.5, color: c)
            .copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.6),
      ),
    );
  }
}

/// Glowing status dot; [pulse] adds a slow breathing halo (frozen with
/// reduced motion).
class HudDot extends StatefulWidget {
  const HudDot({
    super.key,
    required this.color,
    this.size = 7,
    this.pulse = false,
  });
  final Color color;
  final double size;
  final bool pulse;

  @override
  State<HudDot> createState() => _HudDotState();
}

class _HudDotState extends State<HudDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(HudDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final animate = widget.pulse && !AppMotion.reduced(context);
    if (animate && !_c.isAnimating) {
      _c.repeat();
    } else if (!animate && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final c = widget.color;
    final glow = context.hud.glowStrength;
    return SizedBox.square(
      dimension: s * 2.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.pulse)
                Container(
                  width: s * (1 + 1.6 * t),
                  height: s * (1 + 1.6 * t),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c.withValues(alpha: 0.55 * (1 - t)),
                    ),
                  ),
                ),
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.8 * glow),
                      blurRadius: s,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows & steps
// ---------------------------------------------------------------------------

/// Pressable list row for glass cards: leading badge, title, subtitle,
/// trailing widget and a chevron when tappable. Springs + light haptic.
class HudRow extends StatelessWidget {
  const HudRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.footer,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
    this.semanticLabel,
    this.titleStyle,
    this.chevron = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Extra line under the subtitle (e.g. a `SourceBadge`).
  final Widget? footer;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final TextStyle? titleStyle;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: titleStyle ?? t.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (footer != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: footer,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
          if (onTap != null && chevron) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right, size: 20, color: hud.textMuted),
          ],
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      child: PressableScale(onTap: onTap, pressedScale: 0.975, child: row),
    );
  }
}

/// Square glass badge for list leading icons (consistent 40 dp).
class HudBadge extends StatelessWidget {
  const HudBadge({
    super.key,
    this.icon,
    this.text,
    required this.color,
    this.size = 40,
  });
  final IconData? icon;
  final String? text;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: hud.isDark ? 0.22 : 0.16),
            color.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.38)),
      ),
      child: text != null
          ? Text(
              text!,
              style: hud
                  .mono(size: size * 0.3, color: color)
                  .copyWith(fontWeight: FontWeight.w600),
            )
          : Icon(
              icon,
              size: size * 0.5,
              color: color,
              shadows: AppGlows.text(color, strength: 0.6 * hud.glowStrength),
            ),
    );
  }
}

/// One step in a [HudSteps] list.
class HudStep {
  const HudStep(this.title, this.body, {this.done = false, this.action});
  final String title;
  final String body;
  final bool done;
  final Widget? action;
}

/// Numbered setup steps joined by a luminous rail. Done steps glow green; the
/// first open step is the "current" one (cyan).
class HudSteps extends StatelessWidget {
  const HudSteps({super.key, required this.steps});
  final List<HudStep> steps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final current = steps.indexWhere((s) => !s.done);
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 30,
                  child: Column(
                    children: [
                      _StepNode(
                        index: i,
                        done: steps[i].done,
                        current: i == current,
                      ),
                      if (i < steps.length - 1)
                        Expanded(
                          child: Container(
                            width: 1.2,
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  (steps[i].done
                                          ? AppColors.success
                                          : hud.hairline)
                                      .withValues(alpha: 0.5),
                                  hud.hairline.withValues(alpha: 0.12),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: 3,
                      bottom: i == steps.length - 1 ? 0 : AppSpacing.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          steps[i].title,
                          style: t.titleSmall?.copyWith(
                            color: steps[i].done ? hud.textMuted : null,
                            decoration: steps[i].done
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: hud.textMuted,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          steps[i].body,
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                        ),
                        if (steps[i].action != null) ...[
                          const SizedBox(height: AppSpacing.sm),
                          steps[i].action!,
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StepNode extends StatelessWidget {
  const _StepNode({
    required this.index,
    required this.done,
    required this.current,
  });
  final int index;
  final bool done;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = done
        ? AppColors.success
        : current
        ? hud.accent
        : hud.textMuted;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: done || current ? 0.16 : 0.05),
        border: Border.all(color: c.withValues(alpha: current ? 0.9 : 0.45)),
        boxShadow: current
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.45 * hud.glowStrength),
                  blurRadius: 10,
                ),
              ]
            : null,
      ),
      child: done
          ? Icon(Icons.check, size: 14, color: c)
          : Text(
              (index + 1).toString().padLeft(2, '0'),
              style: hud
                  .mono(size: 10, color: c)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
    );
  }
}

/// Thin labelled divider used between groups inside one card.
class HudDivider extends StatelessWidget {
  const HudDivider({super.key, this.height = AppSpacing.lg});
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              context.hud.hairline.withValues(alpha: 0.0),
              context.hud.hairline.withValues(alpha: 0.18),
              context.hud.hairline.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A thin animated glowing progress track.
class HudTrack extends StatelessWidget {
  const HudTrack({super.key, required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return LayoutBuilder(
      builder: (context, box) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
        duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.long,
        curve: AppMotion.emphasizedDecelerate,
        builder: (context, v, _) => Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: hud.hairline.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: box.maxWidth * v,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: 0.5), color],
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.6 * hud.glowStrength),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats a signed delta with a real minus sign: "+2.5", "−1.0".
String signed(num v, {int digits = 1, String unit = ''}) {
  final s = v.abs().toStringAsFixed(digits);
  return '${v < 0 ? '−' : '+'}$s$unit';
}

/// Short weekday letter for an ISO weekday (1 = Monday).
const weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const weekdayShort = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
