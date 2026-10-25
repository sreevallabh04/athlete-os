import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/widgets/widgets.dart';
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
            gridData: HudChartStyle.grid(context),
            borderData: HudChartStyle.noBorder,
            titlesData: HudChartStyle.titles(
              context,
              bottom: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= labels.length || i % step != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    labels[i].toUpperCase(),
                    style: HudChartStyle.axisLabel(context),
                  ),
                );
              },
            ),
            barTouchData: HudChartStyle.barTouch(
              context,
              format: (group, rod) =>
                  '${labels[group.x]}\n${fmt(rod.toY)} $unit',
            ),
            barGroups: [
              for (var i = 0; i < values.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    HudChartStyle.rod(
                      values[i],
                      color,
                      width: labels.length > 20 ? 6 : 14,
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
            gridData: HudChartStyle.grid(context),
            borderData: HudChartStyle.noBorder,
            titlesData: HudChartStyle.titles(
              context,
              leftReserved: 40,
              bottomInterval: maxX <= 6 ? 1 : (maxX / 4).ceilToDouble(),
              left: (v, meta) => Text(
                v.toStringAsFixed(maxY - minY < 10 ? 1 : 0),
                style: HudChartStyle.axisLabel(context),
              ),
              bottom: (v, meta) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  label(v).toUpperCase(),
                  style: HudChartStyle.axisLabel(context),
                ),
              ),
            ),
            lineTouchData: HudChartStyle.lineTouch(
              context,
              format: (s) =>
                  '${lines[s.barIndex].label}\n${label(s.x)}: '
                  '${s.y.toStringAsFixed(1)} $unit',
            ),
            lineBarsData: [
              for (final l in lines)
                l.dotsOnly
                    ? HudChartStyle.line(
                        [for (final p in l.points) FlSpot(x(p.date), p.value)],
                        l.color,
                        curved: false,
                        fill: false,
                        dots: true,
                        width: 0,
                      )
                    : HudChartStyle.line(
                        [for (final p in l.points) FlSpot(x(p.date), p.value)],
                        l.color,
                        dots: l.points.length < 3,
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
    final hud = context.hud;
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        for (final (c, l) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.7 * hud.glowStrength),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(l.toUpperCase(), style: hud.label(size: 10)),
            ],
          ),
      ],
    );
  }
}
