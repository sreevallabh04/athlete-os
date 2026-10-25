import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../../core/time/clock.dart';

/// One bar: a local date key and its value (null = no data, drawn empty).
typedef DayValue = ({String date, double? value});

/// Daily bar chart with an optional dashed goal line. Days without data are
/// left blank — never drawn as zero-height "measured" bars.
class DailyBarChart extends StatelessWidget {
  const DailyBarChart({
    super.key,
    required this.values,
    required this.color,
    this.goal,
    this.height = 180,
    this.semanticLabel,
    this.highlight,
    this.formatValue,
  });

  final List<DayValue> values;
  final Color color;
  final double? goal;
  final double height;
  final String? semanticLabel;

  /// Bars whose date satisfies this get a muted colour (e.g. manual).
  final bool Function(String date)? highlight;
  final String Function(double v)? formatValue;

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final maxVal = values.fold<double>(0, (m, v) => math.max(m, v.value ?? 0));
    final maxY = math.max(maxVal, goal ?? 0) * 1.15;
    final dense = values.length > 10;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: height,
        child: BarChart(
          BarChartData(
            maxY: maxY <= 0 ? 1 : maxY,
            minY: 0,
            alignment: BarChartAlignment.spaceAround,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, _) {
                  final d = values[group.x];
                  final label = d.value == null
                      ? 'No data'
                      : (formatValue?.call(rod.toY) ??
                            rod.toY.round().toString());
                  return BarTooltipItem(
                    '${d.date.substring(5)}\n$label',
                    t.labelSmall ?? const TextStyle(),
                  );
                },
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
                  getTitlesWidget: (value, meta) {
                    final i = value.toInt();
                    if (i < 0 || i >= values.length) {
                      return const SizedBox.shrink();
                    }
                    // Dense charts: label every 5th day counting back from
                    // today.
                    if (dense && (values.length - 1 - i) % 5 != 0) {
                      return const SizedBox.shrink();
                    }
                    final d = LocalDates.parse(values[i].date);
                    final label = dense ? '${d.day}' : _weekdays[d.weekday - 1];
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        label,
                        style: t.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            extraLinesData: goal == null || goal! <= 0
                ? null
                : ExtraLinesData(
                    horizontalLines: [
                      HorizontalLine(
                        y: goal!,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        strokeWidth: 1,
                        dashArray: const [4, 4],
                      ),
                    ],
                  ),
            barGroups: [
              for (var i = 0; i < values.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: values[i].value ?? 0,
                      width: dense ? 6 : 18,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                      color: (highlight?.call(values[i].date) ?? false)
                          ? color.withValues(alpha: 0.45)
                          : (goal != null && (values[i].value ?? 0) >= goal!)
                          ? color
                          : color.withValues(alpha: 0.75),
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

/// Simple weight trend line (points sorted oldest → newest).
class TrendLineChart extends StatelessWidget {
  const TrendLineChart({
    super.key,
    required this.points,
    required this.color,
    this.height = 160,
    this.semanticLabel,
  });

  final List<({DateTime at, double value, bool manual})> points;
  final Color color;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return SizedBox(height: height);
    final minV = points.map((p) => p.value).reduce(math.min);
    final maxV = points.map((p) => p.value).reduce(math.max);
    final pad = math.max(0.5, (maxV - minV) * 0.2);
    final t0 = points.first.at.millisecondsSinceEpoch.toDouble();
    double x(DateTime d) => (d.millisecondsSinceEpoch - t0) / 3600000 / 24;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: height,
        child: LineChart(
          LineChartData(
            minY: minV - pad,
            maxY: maxV + pad,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: const FlTitlesData(
              topTitles: AxisTitles(),
              rightTitles: AxisTitles(),
              bottomTitles: AxisTitles(),
              leftTitles: AxisTitles(),
            ),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: [for (final p in points) FlSpot(x(p.at), p.value)],
                color: color,
                barWidth: 2,
                isCurved: false,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, _, _, i) => FlDotCirclePainter(
                    radius: 3,
                    color: points[i].manual ? scheme.surface : color,
                    strokeWidth: 2,
                    strokeColor: color,
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
