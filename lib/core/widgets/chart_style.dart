import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme/hud_theme.dart';
import '../theme/typography.dart';

/// fl_chart presets so every chart in the app shares the HUD look:
/// glowing lines with gradient fills, minimal dashed grids, technical axis
/// labels and frosted tooltips.
///
/// ```dart
/// LineChart(LineChartData(
///   gridData: HudChartStyle.grid(context),
///   borderData: HudChartStyle.noBorder,
///   titlesData: HudChartStyle.titles(context, bottom: (v, m) => Text('$v')),
///   lineTouchData: HudChartStyle.lineTouch(context, unit: 'kg'),
///   lineBarsData: [HudChartStyle.line(spots, AppColors.strength)],
/// ))
/// ```
abstract final class HudChartStyle {
  static FlBorderData get noBorder => FlBorderData(show: false);

  /// Horizontal dashed hairlines only.
  static FlGridData grid(
    BuildContext context, {
    bool vertical = false,
    double? interval,
  }) {
    final hud = HudTheme.of(context);
    FlLine line(double _) => FlLine(
      color: hud.hairline.withValues(alpha: hud.isDark ? 0.10 : 0.18),
      strokeWidth: 1,
      dashArray: const [3, 4],
    );
    return FlGridData(
      drawVerticalLine: vertical,
      horizontalInterval: interval,
      getDrawingHorizontalLine: line,
      getDrawingVerticalLine: line,
    );
  }

  /// Axis label style (technical, muted).
  static TextStyle axisLabel(BuildContext context) =>
      AppTypography.hudLabel(HudTheme.of(context).textMuted, size: 10.5);

  /// Titles with only the axes you pass enabled.
  static FlTitlesData titles(
    BuildContext context, {
    Widget Function(double value, TitleMeta meta)? bottom,
    Widget Function(double value, TitleMeta meta)? left,
    double bottomReserved = 22,
    double leftReserved = 34,
    double? bottomInterval,
    double? leftInterval,
  }) => FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    bottomTitles: bottom == null
        ? const AxisTitles()
        : AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: bottomReserved,
              interval: bottomInterval,
              getTitlesWidget: bottom,
            ),
          ),
    leftTitles: left == null
        ? const AxisTitles()
        : AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: leftReserved,
              interval: leftInterval,
              getTitlesWidget: left,
            ),
          ),
  );

  /// A glowing line with a fading gradient fill.
  static LineChartBarData line(
    List<FlSpot> spots,
    Color color, {
    bool curved = true,
    bool fill = true,
    bool dots = false,
    double width = 2.5,
    List<int> dashArray = const [],
  }) => LineChartBarData(
    spots: spots,
    isCurved: curved,
    preventCurveOverShooting: true,
    curveSmoothness: 0.3,
    color: color,
    barWidth: width,
    isStrokeCapRound: true,
    dashArray: dashArray.isEmpty ? null : dashArray,
    shadow: Shadow(color: color.withValues(alpha: 0.65), blurRadius: 10),
    dotData: FlDotData(
      show: dots,
      getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
        radius: 3,
        color: Color.lerp(color, Colors.white, 0.6)!,
        strokeWidth: 2,
        strokeColor: color,
      ),
    ),
    belowBarData: BarAreaData(
      show: fill,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.0)],
      ),
    ),
  );

  /// A luminous bar rod (gradient from dim base to bright cap).
  static BarChartRodData rod(
    double y,
    Color color, {
    double width = 12,
    double? backgroundMax,
  }) => BarChartRodData(
    toY: y,
    width: width,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
    gradient: LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [color.withValues(alpha: 0.45), color],
    ),
    backDrawRodData: BackgroundBarChartRodData(
      show: backgroundMax != null,
      toY: backgroundMax ?? 0,
      color: color.withValues(alpha: 0.08),
    ),
  );

  static Color _tooltipBg(HudTheme hud) =>
      hud.isDark ? const Color(0xF2151417) : const Color(0xF7FFFFFF);

  static BorderSide _tooltipBorder(HudTheme hud) =>
      BorderSide(color: hud.hairline.withValues(alpha: 0.3));

  /// Frosted HUD tooltip for line charts. [format] builds the label.
  static LineTouchData lineTouch(
    BuildContext context, {
    String unit = '',
    String Function(LineBarSpot spot)? format,
  }) {
    final hud = HudTheme.of(context);
    final style = AppTypography.mono(
      hud.text,
      size: 12,
    ).copyWith(fontWeight: FontWeight.w600);
    return LineTouchData(
      getTouchedSpotIndicator: (bar, indexes) => [
        for (final _ in indexes)
          TouchedSpotIndicatorData(
            FlLine(
              color: hud.hairline.withValues(alpha: 0.35),
              strokeWidth: 1,
              dashArray: const [2, 3],
            ),
            FlDotData(
              getDotPainter: (spot, _, b, _) => FlDotCirclePainter(
                radius: 4.5,
                color: Colors.white,
                strokeWidth: 3,
                strokeColor: b.color ?? hud.accent,
              ),
            ),
          ),
      ],
      touchTooltipData: LineTouchTooltipData(
        getTooltipColor: (_) => _tooltipBg(hud),
        tooltipBorder: _tooltipBorder(hud),
        tooltipBorderRadius: BorderRadius.circular(8),
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        getTooltipItems: (spots) => [
          for (final s in spots)
            LineTooltipItem(
              format?.call(s) ?? '${_fmt(s.y)}$unit',
              style.copyWith(color: s.bar.color ?? hud.text),
            ),
        ],
      ),
    );
  }

  /// Frosted HUD tooltip for bar charts.
  static BarTouchData barTouch(
    BuildContext context, {
    String unit = '',
    String Function(BarChartGroupData group, BarChartRodData rod)? format,
  }) {
    final hud = HudTheme.of(context);
    final style = AppTypography.mono(
      hud.text,
      size: 12,
    ).copyWith(fontWeight: FontWeight.w600);
    return BarTouchData(
      touchTooltipData: BarTouchTooltipData(
        getTooltipColor: (_) => _tooltipBg(hud),
        tooltipBorder: _tooltipBorder(hud),
        tooltipBorderRadius: BorderRadius.circular(8),
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        getTooltipItem: (group, _, rod, _) => BarTooltipItem(
          format?.call(group, rod) ?? '${_fmt(rod.toY)}$unit',
          style,
        ),
      ),
    );
  }

  static String _fmt(double v) => v.abs() >= 100 || v == v.roundToDouble()
      ? v.round().toString()
      : v.toStringAsFixed(1);
}
