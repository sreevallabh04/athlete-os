import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Minimal themed line chart. [points] are (x, y); [yLabel] formats ticks.
class TrendLineChart extends StatelessWidget {
  const TrendLineChart({
    super.key,
    required this.points,
    required this.color,
    required this.semanticLabel,
    this.yLabel,
    this.xLabel,
    this.height = 180,
    this.curved = true,
    this.showDots = true,
  });

  final List<(double, double)> points;
  final Color color;
  final String semanticLabel;
  final String Function(double)? yLabel;
  final String Function(double)? xLabel;
  final double height;
  final bool curved;
  final bool showDots;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    if (points.isEmpty) return SizedBox(height: height);
    final ys = points.map((p) => p.$2).where((y) => y.isFinite).toList();
    var minY = ys.reduce(math.min);
    var maxY = ys.reduce(math.max);
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY) * 0.12;
    final xs = points.map((p) => p.$1).toList();
    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        height: height,
        child: LineChart(
          LineChartData(
            minY: minY - pad,
            maxY: maxY + pad,
            minX: xs.reduce(math.min),
            maxX: xs.reduce(math.max) == xs.reduce(math.min)
                ? xs.first + 1
                : xs.reduce(math.max),
            gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 48,
                  getTitlesWidget: (v, meta) {
                    if (v == meta.max || v == meta.min) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        yLabel?.call(v) ?? meta.formattedValue,
                        style: style,
                      ),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: xLabel != null,
                  reservedSize: 24,
                  interval: math.max(1, (xs.length / 4).ceilToDouble()),
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text(xLabel?.call(v) ?? '', style: style),
                  ),
                ),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: [for (final p in points) FlSpot(p.$1, p.$2)],
                isCurved: curved,
                preventCurveOverShooting: true,
                color: color,
                barWidth: 3,
                isStrokeCapRound: true,
                dotData: FlDotData(show: showDots && points.length <= 30),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      color.withValues(alpha: 0.25),
                      color.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Simple bar chart with bottom labels.
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.color,
    required this.semanticLabel,
    this.height = 160,
    this.highlightLast = true,
    this.valueLabel,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final String semanticLabel;
  final double height;
  final bool highlightLast;
  final String Function(double)? valueLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final maxV = values.isEmpty ? 1.0 : math.max(1.0, values.reduce(math.max));
    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        height: height,
        child: BarChart(
          BarChartData(
            maxY: maxV * 1.15,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                  valueLabel?.call(rod.toY) ?? rod.toY.toStringAsFixed(0),
                  TextStyle(color: scheme.onSurface),
                ),
              ),
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        i >= 0 && i < labels.length ? labels[i] : '',
                        style: style,
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < values.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: values[i],
                      width: 14,
                      borderRadius: BorderRadius.circular(5),
                      color: highlightLast && i == values.length - 1
                          ? color
                          : color.withValues(alpha: 0.55),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny trend line without axes.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.width = 72,
    this.height = 28,
  });
  final List<double> values;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return SizedBox(width: width, height: height);
    final minY = values.reduce(math.min);
    final maxY = values.reduce(math.max);
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        height: height,
        child: LineChart(
          LineChartData(
            minY: minY == maxY ? minY - 1 : minY,
            maxY: minY == maxY ? maxY + 1 : maxY,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: [
                  for (var i = 0; i < values.length; i++)
                    FlSpot(i.toDouble(), values[i]),
                ],
                isCurved: true,
                preventCurveOverShooting: true,
                color: color,
                barWidth: 2,
                dotData: const FlDotData(show: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
