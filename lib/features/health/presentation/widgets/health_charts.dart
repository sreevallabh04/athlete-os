import 'package:flutter/material.dart';

import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../train/presentation/widgets/hud_kit.dart';

/// One bar: a local date key and its value (null = no data, drawn as a
/// faint tick — never as a measured zero).
typedef DayValue = ({String date, double? value});

/// Daily HUD bar chart with an optional dashed gold goal line, scrubbing
/// tooltips and a selection haptic per bar. Today (the last day) glows.
class DailyBarChart extends StatelessWidget {
  const DailyBarChart({
    super.key,
    required this.values,
    required this.color,
    this.goal,
    this.goalLabel,
    this.height = 170,
    this.semanticLabel,
    this.highlight,
    this.formatValue,
  });

  final List<DayValue> values;
  final Color color;
  final double? goal;
  final String? goalLabel;
  final double height;
  final String? semanticLabel;

  /// Bars whose date satisfies this are drawn faded (e.g. manual entries).
  final bool Function(String date)? highlight;
  final String Function(double v)? formatValue;

  @override
  Widget build(BuildContext context) {
    final dense = values.length > 10;
    final n = values.length;
    return HudBarChart(
      values: [for (final v in values) v.value],
      labels: [
        for (var i = 0; i < n; i++)
          () {
            final d = LocalDates.parse(values[i].date);
            if (!dense) return weekdayLetters[d.weekday - 1];
            return (n - 1 - i) % 5 == 0 ? '${d.day}' : '';
          }(),
      ],
      color: color,
      height: height,
      goal: goal,
      goalLabel: goalLabel,
      highlight: n - 1,
      semanticLabel: semanticLabel ?? 'Daily values',
      colorFor: (i, v) {
        if (highlight?.call(values[i].date) ?? false) {
          return color.withValues(alpha: 0.38);
        }
        if (i == n - 1 || (goal != null && v >= goal!)) return color;
        return color.withValues(alpha: 0.62);
      },
      tooltip: (i, v) {
        final d = Fmt.weekdayDayMonth(LocalDates.parse(values[i].date));
        if (v == null) return '$d\nNo data';
        return '$d\n${formatValue?.call(v) ?? v.round().toString()}'
            '${(highlight?.call(values[i].date) ?? false) ? ' · manual' : ''}';
      },
    );
  }
}
