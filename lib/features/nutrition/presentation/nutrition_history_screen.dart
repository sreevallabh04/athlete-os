import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../application/providers.dart';
import '../data/mappers.dart';
import '../data/weight_query.dart';
import '../domain/csv_export.dart';
import '../domain/nutrition_calc.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';

class NutritionHistoryScreen extends ConsumerStatefulWidget {
  const NutritionHistoryScreen({super.key});

  @override
  ConsumerState<NutritionHistoryScreen> createState() =>
      _NutritionHistoryScreenState();
}

class _NutritionHistoryScreenState
    extends ConsumerState<NutritionHistoryScreen> {
  int _days = 7;
  bool _exporting = false;

  Future<void> _export(String defaultStart, String end) async {
    final now = ref.read(clockProvider).now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: LocalDates.parse(defaultStart),
        end: LocalDates.parse(end),
      ),
      helpText: 'Export food log',
    );
    if (range == null || !mounted) return;
    setState(() => _exporting = true);
    try {
      final start = LocalDates.key(range.start);
      final stop = LocalDates.key(range.end);
      final rows = await ref.read(foodLogRepositoryProvider).range(start, stop);
      if (rows.isEmpty) {
        if (mounted) showSnack(context, 'No food logged in that range');
        return;
      }
      final csv = buildFoodLogCsv(rows.map((e) => e.csvRow));
      final dir = await getTemporaryDirectory();
      final file = File(
        p.join(dir.path, 'athlete_os_food_log_${start}_$stop.csv'),
      );
      await file.writeAsString(csv, flush: true);
      Haptics.success();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'Food log $start to $stop',
        ),
      );
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Export failed: ${redactSecrets(e.toString())}');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final start = LocalDates.addDays(today, -(_days - 1));
    final history = ref.watch(nutritionHistoryProvider((start, today)));
    final targets = ref.watch(nutritionTargetsProvider);
    final weights = ref.watch(weightRangeProvider((start, today)));
    final recipes = ref.watch(recipesProvider).value ?? const [];

    return AppPage(
      title: 'Nutrition history',
      eyebrow: 'LAST $_days DAYS · LOGGED DAYS ONLY',
      actions: [
        IconButton(
          tooltip: 'Export food log (CSV)',
          icon: _exporting
              ? const HudSpinner(size: 20)
              : const Icon(Icons.ios_share),
          onPressed: _exporting ? null : () => _export(start, today),
        ),
      ],
      children: [
        SegmentedHud<int>(
          segments: const [
            HudSegment(value: 7, label: '7 days'),
            HudSegment(value: 30, label: '30 days'),
          ],
          value: _days,
          onChanged: (v) => setState(() => _days = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        ...history.when(
          loading: () => [const ScanlineLoader(height: 280, lines: 0)],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (h) => targets.when(
            loading: () => [const ScanlineLoader(height: 280, lines: 0)],
            error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
            data: (t) {
              final avg = PeriodAverages.compute(h.days, t);
              if (!avg.hasData) {
                return [
                  const AppCard(
                    child: EmptyState(
                      icon: Icons.insights_outlined,
                      eyebrow: 'NO DATA YET',
                      title: 'No food logged in this period',
                      message:
                          'Averages and charts appear once you log meals. '
                          'Days without logs are never counted as zero.',
                    ),
                  ),
                ];
              }
              final usual = rankByProteinEfficiency([
                ...usualFoods(h.lines),
                for (final r in recipes)
                  NamedNutrients(
                    name: '${r.recipe.name} (recipe, 1 serving)',
                    nutrients: r.perServing,
                  ),
              ]).take(5).toList();
              final weeks = weeklyAverages(h.days, t, LocalDates.weekStart);
              return [
                _AveragesCard(avg: avg, targets: t),
                const SectionHeader('Calories', subtitle: 'Band = target ±10%'),
                AppCard(
                  child: _DailyBarChart(
                    days: h.days,
                    value: (d) => d.total.calories,
                    target: t.calories,
                    band: 0.10,
                    color: AppColors.calories,
                    unit: 'kcal',
                  ),
                ),
                const SectionHeader(
                  'Protein',
                  subtitle: 'Bright bars hit ≥ 90%',
                ),
                AppCard(
                  child: _DailyBarChart(
                    days: h.days,
                    value: (d) => d.total.protein,
                    target: t.protein,
                    color: AppColors.protein,
                    unit: 'g',
                    hitAt: 0.9,
                  ),
                ),
                if (weeks.length > 1) ...[
                  const SectionHeader(
                    'Weekly averages',
                    subtitle: 'Logged days only',
                  ),
                  AppCard(
                    child: Column(
                      children: [
                        for (final w in weeks.entries.toList().reversed)
                          _WeekRow(weekStart: w.key, avg: w.value, targets: t),
                      ],
                    ),
                  ),
                ],
                const SectionHeader(
                  'Protein-efficient foods',
                  subtitle: 'Your usual foods, ranked',
                ),
                AppCard(
                  child: usual.isEmpty
                      ? const EmptyState(
                          compact: true,
                          icon: Icons.egg_outlined,
                          title: 'Not enough repeats yet',
                          message:
                              'Foods logged at least twice in this period '
                              'and your recipes show up here.',
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < usual.length; i++)
                              _UsualRow(item: usual[i], rank: i + 1),
                          ],
                        ),
                ),
              ];
            },
          ),
        ),
        const SectionHeader('Weight trend'),
        AppCard(
          child: weights.when(
            loading: () => const ScanlineLoader(height: 160, lines: 0),
            error: (e, _) => ErrorState(message: redactSecrets('$e')),
            data: (w) => _WeightTrend(points: w),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton.secondary(
          label: 'Export food log as CSV',
          icon: Icons.table_view_outlined,
          expand: true,
          loading: _exporting,
          onPressed: _exporting ? null : () => _export(start, today),
        ),
      ],
    );
  }
}

class _AveragesCard extends StatelessWidget {
  const _AveragesCard({required this.avg, required this.targets});
  final PeriodAverages avg;
  final NutritionTargets targets;

  @override
  Widget build(BuildContext context) {
    final a = avg.average;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Daily average · ${avg.loggedDays} of ${avg.totalDays} '
                  'days logged',
                  style: t.titleSmall,
                ),
              ),
              const SourceBadge(origin: DataOrigin.calculated),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, box) {
              final w = math.min(150.0, (box.maxWidth - AppSpacing.md) / 2);
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  ArcGauge(
                    value: avg.proteinAdherencePct / 100,
                    valueText: '${avg.proteinAdherencePct.round()}%',
                    label: 'PROTEIN ≥90%',
                    color: AppColors.protein,
                    width: w,
                    semanticLabel:
                        'Protein at least 90% of target on '
                        '${avg.proteinAdherentDays} of ${avg.loggedDays} '
                        'logged days',
                  ),
                  ArcGauge(
                    value: avg.calorieAdherencePct / 100,
                    valueText: '${avg.calorieAdherencePct.round()}%',
                    label: 'KCAL ±10%',
                    color: AppColors.calories,
                    width: w,
                    semanticLabel:
                        'Calories within 10% of target on '
                        '${avg.calorieAdherentDays} of ${avg.loggedDays} '
                        'logged days',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: Text(
              'ADHERENCE ON ${avg.loggedDays} LOGGED DAY'
              '${avg.loggedDays == 1 ? '' : 'S'}',
              style: hud.mono(size: 10),
            ),
          ),
          const Divider(height: AppSpacing.xxl),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Calories',
                  value: Fmt.integer(a.calories),
                  sub: 'target ${Fmt.integer(targets.calories)}',
                  color: AppColors.calories,
                  icon: Icons.local_fire_department_outlined,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Protein',
                  value: Fmt.grams(a.protein),
                  sub: 'target ${Fmt.grams(targets.protein)}',
                  color: AppColors.protein,
                  icon: Icons.egg_alt_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Carbs',
                  value: Fmt.grams(a.carbs),
                  sub: 'target ${Fmt.grams(targets.carbs)}',
                  color: AppColors.carbs,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Fat',
                  value: Fmt.grams(a.fat),
                  sub: 'target ${Fmt.grams(targets.fat)}',
                  color: AppColors.fat,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.weekStart,
    required this.avg,
    required this.targets,
  });

  final String weekStart;
  final PeriodAverages avg;
  final NutritionTargets targets;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final a = avg.average;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Week of '
                  '${DateFormat('d MMM').format(LocalDates.parse(weekStart))}',
                  style: t.titleSmall,
                ),
              ),
              Text(
                avg.hasData
                    ? '${avg.loggedDays}/${avg.totalDays} DAYS'
                    : 'NO LOGS',
                style: hud.mono(size: 10.5),
              ),
            ],
          ),
          if (avg.hasData) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _MiniBar(
                    label: '${Fmt.integer(a.calories)} kcal',
                    ratio: targets.calories > 0
                        ? a.calories / targets.calories
                        : 0,
                    color: AppColors.calories,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _MiniBar(
                    label: '${Fmt.grams(a.protein)} P',
                    ratio: targets.protein > 0
                        ? a.protein / targets.protein
                        : 0,
                    color: AppColors.protein,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({
    required this.label,
    required this.ratio,
    required this.color,
  });
  final String label;
  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.labelMedium?.copyWith(color: hud.textMuted)),
        const SizedBox(height: 4),
        MetricBarLine(ratio: ratio, color: color),
      ],
    );
  }
}

/// Bare continuous progress line (no label); over-target turns warm red.
class MetricBarLine extends StatelessWidget {
  const MetricBarLine({super.key, required this.ratio, required this.color});
  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final over = ratio > 1.1;
    final c = over ? overColor : color;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: ratio.clamp(0.0, 1.0)),
        duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.data,
        curve: AppMotion.emphasizedDecelerate,
        builder: (context, v, _) => LinearProgressIndicator(
          value: v,
          minHeight: 4,
          color: c,
          backgroundColor: color.withValues(alpha: 0.12),
        ),
      ),
    );
  }
}

class _UsualRow extends StatelessWidget {
  const _UsualRow({required this.item, required this.rank});
  final NamedNutrients item;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(width: 28, child: Text('#$rank', style: hud.mono(size: 11))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: t.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  item.timesLogged > 1
                      ? 'Logged ${item.timesLogged}× this period'
                      : macroSummary(item.nutrients),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Fmt.oneDp(item.proteinEfficiency!),
                style: hud.number(
                  size: 22,
                  color: hud.isDark ? AppColors.protein : hud.text,
                ),
              ),
              Text('G / 100 KCAL', style: hud.label(size: 9)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DailyBarChart extends StatelessWidget {
  const _DailyBarChart({
    required this.days,
    required this.value,
    required this.target,
    required this.color,
    required this.unit,
    this.band,
    this.hitAt,
  });

  final List<DaySummary> days;
  final double Function(DaySummary) value;
  final double target;
  final Color color;
  final String unit;

  /// Shade target ± this fraction (e.g. 0.10).
  final double? band;

  /// Bars at or above target × this fraction render bright.
  final double? hitAt;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final maxVal = [
      ...days.map(value),
      target * (1 + (band ?? 0)),
    ].fold<double>(0, (a, b) => a > b ? a : b);
    final maxY = maxVal <= 0 ? 1.0 : maxVal * 1.12;
    final wide = days.length > 10;
    final labelEvery = wide ? 7 : 1;
    final semantics = days
        .map(
          (d) => d.hasLogs
              ? '${d.localDate}: ${Fmt.integer(value(d))} $unit'
              : '${d.localDate}: not logged',
        )
        .join(', ');
    Color barColor(DaySummary d) {
      final v = value(d);
      if (band != null && target > 0 && v > target * (1 + band!)) {
        return overColor;
      }
      if (hitAt != null && target > 0 && v < target * hitAt!) {
        return color.withValues(alpha: 0.5);
      }
      return color;
    }

    return SizedBox(
      height: 200,
      child: Semantics(
        label: semantics,
        excludeSemantics: true,
        child: BarChart(
          BarChartData(
            minY: 0,
            maxY: maxY,
            gridData: HudChartStyle.grid(context),
            borderData: HudChartStyle.noBorder,
            barTouchData: HudChartStyle.barTouch(
              context,
              format: (group, rod) {
                final d = days[group.x];
                final date = DateFormat('EEE d')
                    .format(LocalDates.parse(d.localDate));
                return d.hasLogs
                    ? '$date · ${Fmt.integer(rod.toY)} $unit'
                    : '$date · not logged';
              },
            ),
            rangeAnnotations: RangeAnnotations(
              horizontalRangeAnnotations: [
                if (band != null && target > 0)
                  HorizontalRangeAnnotation(
                    y1: target * (1 - band!),
                    y2: target * (1 + band!),
                    color: color.withValues(alpha: hud.isDark ? 0.08 : 0.12),
                  ),
              ],
            ),
            extraLinesData: ExtraLinesData(
              horizontalLines: [
                if (target > 0)
                  HorizontalLine(
                    y: target,
                    color: color.withValues(alpha: 0.75),
                    strokeWidth: 1,
                    dashArray: [5, 4],
                    label: HorizontalLineLabel(
                      show: true,
                      alignment: Alignment.topRight,
                      style: HudChartStyle.axisLabel(context),
                      labelResolver: (_) => 'TARGET ${Fmt.integer(target)}',
                    ),
                  ),
              ],
            ),
            titlesData: HudChartStyle.titles(
              context,
              left: (v, meta) {
                if (v != meta.max && v != 0) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    Fmt.integer(v),
                    style: HudChartStyle.axisLabel(context),
                  ),
                );
              },
              leftReserved: 40,
              bottom: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= days.length) return const SizedBox.shrink();
                final fromEnd = days.length - 1 - i;
                if (fromEnd % labelEvery != 0) return const SizedBox.shrink();
                final d = LocalDates.parse(days[i].localDate);
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    (wide
                            ? DateFormat('d MMM').format(d)
                            : DateFormat.E().format(d))
                        .toUpperCase(),
                    style: HudChartStyle.axisLabel(context),
                  ),
                );
              },
            ),
            barGroups: [
              for (var i = 0; i < days.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    HudChartStyle.rod(
                      days[i].hasLogs ? value(days[i]) : 0,
                      barColor(days[i]),
                      width: wide ? 6 : 18,
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

class _WeightTrend extends StatelessWidget {
  const _WeightTrend({required this.points});
  final List<WeightPoint> points;

  String _sourceLabel(WeightPoint w) {
    final origin = DataOrigin.fromKey(w.origin).label;
    final app = w.sourceApp;
    if (app == null || app.isEmpty) return origin;
    final short = switch (app) {
      'com.sec.android.app.shealth' => 'Samsung Health',
      'com.google.android.apps.fitness' => 'Google Fit',
      _ => app,
    };
    return '$origin · $short';
  }

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: Icons.monitor_weight_outlined,
        title: 'No weight data in this period',
        message:
            'Weigh-ins from Health Connect (e.g. a Samsung scale) or manual '
            'entries will appear here.',
      );
    }
    final hud = context.hud;
    final first = points.first;
    final last = points.last;
    final change = last.kg - first.kg;
    final sources = points.map(_sourceLabel).toSet().toList()..sort();
    final t0 = first.at.millisecondsSinceEpoch.toDouble();
    final spots = [
      for (final w in points)
        FlSpot((w.at.millisecondsSinceEpoch - t0) / 86400000, w.kg),
    ];
    final minY = points.map((w) => w.kg).reduce((a, b) => a < b ? a : b) - 1;
    final maxY = points.map((w) => w.kg).reduce((a, b) => a > b ? a : b) + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Latest',
                value: '${Fmt.oneDp(last.kg)} kg',
                sub: Fmt.dayMonth(last.at),
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'Change',
                value:
                    '${change >= 0 ? '+' : '−'}${Fmt.oneDp(change.abs())} kg',
                sub:
                    '${points.length} weigh-in${points.length == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
        if (points.length > 1) ...[
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 160,
            child: Semantics(
              label:
                  'Weight from ${Fmt.oneDp(first.kg)} to ${Fmt.oneDp(last.kg)} kg',
              excludeSemantics: true,
              child: LineChart(
                LineChartData(
                  minY: minY,
                  maxY: maxY,
                  gridData: HudChartStyle.grid(context),
                  borderData: HudChartStyle.noBorder,
                  titlesData: HudChartStyle.titles(
                    context,
                    left: (v, meta) => v == meta.min || v == meta.max
                        ? const SizedBox.shrink()
                        : SideTitleWidget(
                            meta: meta,
                            child: Text(
                              Fmt.oneDp(v),
                              style: HudChartStyle.axisLabel(context),
                            ),
                          ),
                  ),
                  lineTouchData: HudChartStyle.lineTouch(
                    context,
                    format: (s) => '${Fmt.oneDp(s.y)} kg',
                  ),
                  lineBarsData: [
                    HudChartStyle.line(spots, hud.accent, dots: true),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          'Sources: ${sources.join(', ')}',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: hud.textMuted),
        ),
      ],
    );
  }
}
