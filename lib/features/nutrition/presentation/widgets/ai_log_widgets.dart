import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/food_log_review.dart';
import '../../domain/food_models.dart';
import '../../domain/nutrition_calc.dart';
import 'common.dart';

/// Categorical meal hues for the AI log charts (dawn → dusk, one warm
/// family with alternating luminance). Used only to
/// tell meals apart inside these charts, always with a legend.
Color mealColor(MealType m) => switch (m) {
  MealType.breakfast => AppColors.goldLight,
  MealType.lunch => AppColors.carbs,
  MealType.dinner => AppColors.fat,
  MealType.snack => AppColors.titanium,
};

/// Confidence → colour: success ≥ 0.75, warning ≥ 0.5, red below.
Color confidenceColor(double? c) {
  if (c == null) return AppColors.warning;
  if (c >= 0.75) return AppColors.success;
  if (c >= FoodLogLimits.lowConfidence) return AppColors.warning;
  return AppColors.danger;
}

String confidenceLabel(double? c) {
  if (c == null) return 'Confidence unknown';
  final pct = (c * 100).round();
  if (c >= 0.75) return 'High confidence ($pct%)';
  if (c >= FoodLogLimits.lowConfidence) return 'Medium confidence ($pct%)';
  return 'Low confidence ($pct%): check the portion';
}

/// Small glowing status dot.
class ConfidenceDot extends StatelessWidget {
  const ConfidenceDot({super.key, required this.confidence, this.size = 8});
  final double? confidence;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = confidenceColor(confidence);
    return Tooltip(
      message: confidenceLabel(confidence),
      child: Semantics(
        label: confidenceLabel(confidence),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c,
            boxShadow: [
              BoxShadow(
                color: c.withValues(alpha: 0.7 * context.hud.glowStrength),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// P/C/F energy donut (fl_chart, HUD styled) with the protein share in the
/// centre.
class MacroDonut extends StatelessWidget {
  const MacroDonut({super.key, required this.split, this.size = 132});
  final MacroSplit split;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final (p, c, f) = split.roundedPercents();
    final ring = size * 0.13;
    PieChartSectionData section(double v, Color color) => PieChartSectionData(
      value: v <= 0 ? 0.0001 : v,
      color: color,
      radius: ring,
      showTitle: false,
      borderSide: BorderSide(color: color.withValues(alpha: 0.9), width: 0.5),
    );
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label:
          'Energy split: protein $p percent, carbs $c percent, fat $f percent',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Soft bloom behind the ring.
            Container(
              width: size * 0.8,
              height: size * 0.8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: AppGlows.soft(
                  AppColors.protein,
                  strength: hud.glowStrength * 0.5,
                ),
              ),
            ),
            PieChart(
              PieChartData(
                sections: split.isEmpty
                    ? [section(1, hud.text.withValues(alpha: 0.1))]
                    : [
                        section(split.proteinKcal, AppColors.protein),
                        section(split.carbsKcal, AppColors.carbs),
                        section(split.fatKcal, AppColors.fat),
                      ],
                centerSpaceRadius: size / 2 - ring,
                sectionsSpace: 2.5,
                startDegreeOffset: -90,
                borderData: FlBorderData(show: false),
                pieTouchData: PieTouchData(enabled: false),
              ),
              duration: reduced ? Duration.zero : AppMotion.data,
              curve: AppMotion.emphasizedDecelerate,
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$p%',
                  style: hud.number(size: size * 0.2, color: AppColors.protein),
                ),
                Text('PROTEIN', style: hud.label(size: 9.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Legend row for the donut: "● P 28%  ● C 46%  ● F 26%".
class MacroLegend extends StatelessWidget {
  const MacroLegend({super.key, required this.split});
  final MacroSplit split;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final (p, c, f) = split.roundedPercents();
    Widget item(String l, int v, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text('$l $v%', style: hud.mono(size: 10.5, color: hud.text)),
      ],
    );
    return ExcludeSemantics(
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 4,
        children: [
          item('P', p, AppColors.protein),
          item('C', c, AppColors.carbs),
          item('F', f, AppColors.fat),
        ],
      ),
    );
  }
}

/// Meal legend chips for the per-item chart.
class MealLegend extends StatelessWidget {
  const MealLegend({super.key, required this.meals});
  final List<MealType> meals;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final m in meals)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 4,
                decoration: BoxDecoration(
                  color: mealColor(m),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 5),
              Text(m.label.toUpperCase(), style: hud.label(size: 10)),
            ],
          ),
      ],
    );
  }
}

/// Horizontal "calories per item" bars, sorted high → low, coloured by meal.
/// Bars sweep in on arrival (reduced motion: instant).
class ItemCaloriesChart extends StatelessWidget {
  const ItemCaloriesChart({super.key, required this.items, this.maxRows = 10});
  final List<ReviewItem> items;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final sorted = [...items]
      ..sort((a, b) => b.nutrients.calories.compareTo(a.nutrients.calories));
    final shown = sorted.take(maxRows).toList();
    final rest = sorted.skip(maxRows).toList();
    final maxKcal = math.max(
      1.0,
      shown.isEmpty ? 1.0 : shown.first.nutrients.calories,
    );
    final reduced = AppMotion.reduced(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Semantics(
              label:
                  '${shown[i].name}, ${Fmt.kcal(shown[i].nutrients.calories)}, '
                  '${shown[i].mealType.label}',
              excludeSemantics: true,
              child: Row(
                children: [
                  SizedBox(
                    width: 108,
                    child: Text(
                      shown[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: hud.text),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: 0,
                        end: shown[i].nutrients.calories / maxKcal,
                      ),
                      duration: reduced
                          ? Duration.zero
                          : AppMotion.data + Duration(milliseconds: 45 * i),
                      curve: AppMotion.emphasizedDecelerate,
                      builder: (context, v, _) => _Bar(
                        fraction: v,
                        color: mealColor(shown[i].mealType),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 40,
                    child: Text(
                      Fmt.integer(shown[i].nutrients.calories),
                      textAlign: TextAlign.right,
                      style: hud.mono(size: 11, color: hud.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (rest.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+ ${rest.length} more · '
              '${Fmt.kcal(rest.fold(0.0, (a, e) => a + e.nutrients.calories))}',
              style: hud.mono(size: 10.5),
            ),
          ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return LayoutBuilder(
      builder: (context, box) {
        final w = math.max(3.0, box.maxWidth * fraction.clamp(0.0, 1.0));
        return Stack(
          children: [
            Container(
              height: 10,
              decoration: BoxDecoration(
                color: hud.text.withValues(alpha: hud.isDark ? 0.05 : 0.06),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Container(
              width: w,
              height: 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: 0.45), color],
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45 * hud.glowStrength),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Before → after against a daily target: dim segment = already logged,
/// bright segment = this paste, tick = target. Over target turns the
/// overflow warm red and says "over by".
class ImpactBar extends StatelessWidget {
  const ImpactBar({
    super.key,
    required this.label,
    required this.line,
    required this.color,
    required this.unit,
    this.fmt = Fmt.integer,
    this.compact = false,
  });

  /// Half-width layout: no "before" figure, status only underneath.
  final bool compact;
  final String label;
  final ImpactLine line;
  final Color color;
  final String unit;
  final String Function(num) fmt;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final target = line.target;
    final scale = math.max(1.0, math.max(line.after, target ?? 0) * 1.0);
    final beforeF = (line.before / scale).clamp(0.0, 1.0);
    final afterF = (line.after / scale).clamp(0.0, 1.0);
    final targetF = target == null ? null : (target / scale).clamp(0.0, 1.0);
    final after = line.remainingAfter;
    final status = !line.hasTarget
        ? 'No target set'
        : after.isOver
        ? 'Over by ${fmt(after.overBy)} $unit'
        : '${fmt(after.value!)} $unit left';
    final statusColor = after.isOver
        ? hud.ink(AppColors.danger)
        : hud.textMuted;
    final statusStyle = t.bodySmall?.copyWith(
      color: statusColor,
      fontWeight: after.isOver ? FontWeight.w600 : null,
    );
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label:
          '$label: ${fmt(line.before)} now, ${fmt(line.after)} after logging'
          '${target == null ? '' : ' of ${fmt(target)} $unit'}. $status',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label, style: hud.label(size: 11)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (!compact) ...[
                        TextSpan(
                          text: fmt(line.before),
                          style: hud.mono(size: 11.5),
                        ),
                        TextSpan(
                          text: '  →  ',
                          style: hud.mono(size: 11.5, color: color),
                        ),
                      ],
                      TextSpan(
                        text: fmt(line.after),
                        style: hud
                            .number(size: 18, color: hud.text)
                            .copyWith(height: 1),
                      ),
                      if (target != null)
                        TextSpan(
                          text: compact
                              ? ' / ${fmt(target)}'
                              : ' / ${fmt(target)} $unit',
                          style: hud.mono(size: 11),
                        ),
                    ],
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: beforeF, end: afterF),
            duration: reduced ? Duration.zero : AppMotion.data,
            curve: AppMotion.emphasizedDecelerate,
            builder: (context, a, _) => SizedBox(
              height: 14,
              child: CustomPaint(
                painter: _ImpactPainter(
                  before: beforeF,
                  after: a,
                  target: targetF,
                  color: color,
                  over: hud.ink(AppColors.danger),
                  track: hud.text.withValues(alpha: hud.isDark ? 0.06 : 0.07),
                  tick: hud.text,
                  glow: hud.glowStrength,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (compact)
            Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: statusStyle,
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    '+${fmt(line.added)} $unit from this log',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(status, style: statusStyle),
              ],
            ),
        ],
      ),
    );
  }
}

class _ImpactPainter extends CustomPainter {
  _ImpactPainter({
    required this.before,
    required this.after,
    required this.target,
    required this.color,
    required this.over,
    required this.track,
    required this.tick,
    required this.glow,
  });

  final double before;
  final double after;
  final double? target;
  final Color color;
  final Color over;
  final Color track;
  final Color tick;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    const barH = 8.0;
    final top = (size.height - barH) / 2;
    final r = const Radius.circular(3);
    RRect seg(double a, double b) =>
        RRect.fromLTRBR(size.width * a, top, size.width * b, top + barH, r);
    canvas.drawRRect(seg(0, 1), Paint()..color = track);
    if (before > 0) {
      canvas.drawRRect(
        seg(0, before),
        Paint()..color = color.withValues(alpha: 0.35),
      );
    }
    final t = target;
    final addEnd = t == null ? after : math.min(after, t);
    if (addEnd > before) {
      final s = seg(before, addEnd);
      canvas.drawRRect(
        s,
        Paint()
          ..color = color.withValues(alpha: 0.5 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawRRect(s, Paint()..color = color);
    }
    if (t != null && after > t) {
      final start = math.max(t, before);
      final s = seg(start, after);
      canvas.drawRRect(
        s,
        Paint()
          ..color = over.withValues(alpha: 0.5 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawRRect(s, Paint()..color = over);
    }
    if (t != null) {
      final x = size.width * t;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = tick.withValues(alpha: 0.85)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_ImpactPainter old) =>
      old.before != before ||
      old.after != after ||
      old.target != target ||
      old.color != color ||
      old.over != over;
}

/// Macro line for a row: "P 12 · C 30 · F 8".
String compactMacros(ReviewItem i) =>
    'P ${Fmt.integer(i.nutrients.protein)} · '
    'C ${Fmt.integer(i.nutrients.carbs)} · '
    'F ${Fmt.integer(i.nutrients.fat)}';

/// "2 rotis · 80 g".
String portionLabel(ReviewItem i) {
  final parts = [
    if (i.quantity != null) i.quantity!,
    if (i.grams != null) '${plainNum(i.grams!)} g',
  ];
  return parts.isEmpty ? 'Portion estimated' : parts.join(' · ');
}
