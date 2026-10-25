import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../domain/metrics.dart';

String _shortDate(String key) =>
    DateFormat('d MMM').format(LocalDates.parse(key));

/// Interactive bar chart over labelled values (tap a bar for its value).
class LabeledBarChart extends StatelessWidget {
  const LabeledBarChart({
    super.key,
    required this.labels,
    required this.values,
    required this.color,
    required this.unit,
    this.height = 160,
    this.valueFormat,
    this.semanticLabel,
  });

  final List<String> labels;
  final List<double> values;
  final Color color;
  final String unit;
  final double height;
  final String Function(double)? valueFormat;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fmt = valueFormat ?? (double v) => v.toStringAsFixed(v < 10 ? 1 : 0);
    final maxY = values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b);
    final step = (labels.length / 6).ceil().clamp(1, 1000);
    return Semantics(
      label:
          semanticLabel ??
          [
            for (var i = 0; i < labels.length; i++)
              '${labels[i]}: ${fmt(values[i])} $unit',
          ].join(', '),
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: BarChart(
          BarChartData(
            maxY: maxY <= 0 ? 1 : maxY * 1.15,
            alignment: BarChartAlignment.spaceAround,
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
              leftTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= labels.length || i % step != 0) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(labels[i], style: t.labelSmall),
                    );
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => scheme.surfaceContainerHighest,
                getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                  '${labels[group.x]}\n${fmt(rod.toY)} $unit',
                  t.labelMedium ?? const TextStyle(),
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
                      width: labels.length > 20 ? 6 : 14,
                      color: color,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          duration: AppDurations.medium,
        ),
      ),
    );
  }
}

/// A line in [DateLineChart].
class DateLine {
  const DateLine({
    required this.points,
    required this.color,
    required this.label,
    this.dotsOnly = false,
  });
  final List<SeriesPoint> points;
  final Color color;
  final String label;

  /// Raw readings drawn as dots without a connecting line.
  final bool dotsOnly;
}

/// Interactive line chart with a real date x-axis (gaps are not interpolated
/// into fake readings; lines simply connect existing points).
class DateLineChart extends StatelessWidget {
  const DateLineChart({
    super.key,
    required this.lines,
    required this.unit,
    this.height = 180,
  });

  final List<DateLine> lines;
  final String unit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final all = [for (final l in lines) ...l.points];
    if (all.isEmpty) return SizedBox(height: height);
    final dates = all.map((p) => p.date).toList()..sort();
    final first = LocalDates.parse(dates.first);
    double x(String d) =>
        DateTime.utc(
              LocalDates.parse(d).year,
              LocalDates.parse(d).month,
              LocalDates.parse(d).day,
            )
            .difference(DateTime.utc(first.year, first.month, first.day))
            .inDays
            .toDouble();
    final ys = all.map((p) => p.value);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() < 1 ? 1.0 : (maxY - minY) * 0.15;
    final maxX = x(dates.last);
    String label(double v) =>
        DateFormat('d MMM')
            .format(DateTime(first.year, first.month, first.day + v.round()));

    return Semantics(
      label:
          '${lines.map((l) => l.label).join(' and ')} chart, '
          '${all.length} points from ${_shortDate(dates.first)} to '
          '${_shortDate(dates.last)}',
      child: SizedBox(
        height: height,
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX: maxX <= 0 ? 1 : maxX,
            minY: minY - pad,
            maxY: maxY + pad,
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
                  reservedSize: 40,
                  getTitlesWidget: (v, meta) => Text(
                    v.toStringAsFixed(maxY - minY < 10 ? 1 : 0),
                    style: t.labelSmall,
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: maxX <= 6 ? 1 : (maxX / 4).ceilToDouble(),
                  getTitlesWidget: (v, meta) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(label(v), style: t.labelSmall),
                  ),
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => scheme.surfaceContainerHighest,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${lines[s.barIndex].label}\n${label(s.x)}: '
                      '${s.y.toStringAsFixed(1)} $unit',
                      (t.labelSmall ?? const TextStyle()).copyWith(
                        color: lines[s.barIndex].color,
                      ),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (final l in lines)
                LineChartBarData(
                  spots: [for (final p in l.points) FlSpot(x(p.date), p.value)],
                  color: l.color,
                  barWidth: l.dotsOnly ? 0 : 3,
                  isCurved: !l.dotsOnly,
                  preventCurveOverShooting: true,
                  dotData: FlDotData(show: l.dotsOnly || l.points.length < 3),
                  belowBarData: BarAreaData(
                    show: !l.dotsOnly,
                    gradient: LinearGradient(
                      colors: [
                        l.color.withValues(alpha: 0.25),
                        l.color.withValues(alpha: 0.0),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
            ],
          ),
          duration: AppDurations.medium,
        ),
      ),
    );
  }
}

/// Legend dot + label used under charts.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});
  final List<(Color, String)> items;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        for (final (c, l) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text(l, style: t.labelSmall),
            ],
          ),
      ],
    );
  }
}
