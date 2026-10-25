import 'dart:io';

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
      actions: [
        IconButton(
          tooltip: 'Export food log (CSV)',
          icon: _exporting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.ios_share),
          onPressed: _exporting ? null : () => _export(start, today),
        ),
      ],
      children: [
        Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7 days')),
              ButtonSegment(value: 30, label: Text('30 days')),
            ],
            selected: {_days},
            onSelectionChanged: (s) => setState(() => _days = s.first),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        ...history.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (h) => targets.when(
            loading: () => [const LoadingState()],
            error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
            data: (t) {
              final avg = PeriodAverages.compute(h.days, t);
              if (!avg.hasData) {
                return [
                  const AppCard(
                    child: EmptyState(
                      icon: Icons.insights_outlined,
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
                if (weeks.length > 1) ...[
                  const SectionHeader(
                    'Weekly averages',
                    subtitle: 'Logged days only (weeks start Monday)',
                  ),
                  AppCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    child: Column(
                      children: [
                        for (final w in weeks.entries.toList().reversed)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Week of '
                              '${DateFormat('d MMM').format(LocalDates.parse(w.key))}',
                            ),
                            subtitle: Text(
                              w.value.hasData
                                  ? '${w.value.loggedDays} of '
                                        '${w.value.totalDays} days logged'
                                  : 'No logs',
                            ),
                            trailing: w.value.hasData
                                ? Text(
                                    '${Fmt.integer(w.value.average.calories)} kcal'
                                    ' · ${Fmt.grams(w.value.average.protein)} P',
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
                ],
                const SectionHeader(
                  'Calories',
                  subtitle: 'Dashed line = target',
                ),
                AppCard(
                  child: _DailyBarChart(
                    days: h.days,
                    value: (d) => d.total.calories,
                    target: t.calories,
                    color: AppColors.calories,
                    unit: 'kcal',
                  ),
                ),
                const SectionHeader(
                  'Protein',
                  subtitle: 'Dashed line = target',
                ),
                AppCard(
                  child: _DailyBarChart(
                    days: h.days,
                    value: (d) => d.total.protein,
                    target: t.protein,
                    color: AppColors.protein,
                    unit: 'g',
                  ),
                ),
                const SectionHeader(
                  'Most protein-efficient usual foods',
                  subtitle: 'Grams of protein per 100 kcal',
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
                            for (final u in usual)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(u.name),
                                subtitle: Text(
                                  u.timesLogged > 1
                                      ? 'Logged ${u.timesLogged}× · '
                                            '${macroSummary(u.nutrients)}'
                                      : macroSummary(u.nutrients),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text(
                                  '${Fmt.oneDp(u.proteinEfficiency!)} g',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(color: AppColors.protein),
                                ),
                              ),
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
            loading: () => const LoadingState(),
            error: (e, _) => ErrorState(message: redactSecrets('$e')),
            data: (w) => _WeightTrend(points: w),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: _exporting ? null : () => _export(start, today),
          icon: const Icon(Icons.table_view_outlined),
          label: const Text('Export food log as CSV'),
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
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily average · ${avg.loggedDays} of ${avg.totalDays} days logged',
            style: t.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          const SourceBadge(origin: DataOrigin.calculated),
          const SizedBox(height: AppSpacing.lg),
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
                  color: AppColors.carbs,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Fat',
                  value: Fmt.grams(a.fat),
                  color: AppColors.fat,
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.xxl),
          Text('Target adherence (logged days)', style: t.titleSmall),
          const SizedBox(height: AppSpacing.md),
          _AdherenceRow(
            label: 'Protein ≥ 90% of target',
            hit: avg.proteinAdherentDays,
            of: avg.loggedDays,
            pct: avg.proteinAdherencePct,
            color: AppColors.protein,
          ),
          const SizedBox(height: AppSpacing.sm),
          _AdherenceRow(
            label: 'Calories within ±10%',
            hit: avg.calorieAdherentDays,
            of: avg.loggedDays,
            pct: avg.calorieAdherencePct,
            color: AppColors.calories,
          ),
        ],
      ),
    );
  }
}

class _AdherenceRow extends StatelessWidget {
  const _AdherenceRow({
    required this.label,
    required this.hit,
    required this.of,
    required this.pct,
    required this.color,
  });
  final String label;
  final int hit;
  final int of;
  final double pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return MetricBar(
      label: '$label · ${pct.round()}%',
      value: hit.toDouble(),
      target: of.toDouble(),
      color: color,
      unit: ' days',
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
  });

  final List<DaySummary> days;
  final double Function(DaySummary) value;
  final double target;
  final Color color;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxVal = [
      ...days.map(value),
      target,
    ].fold<double>(0, (a, b) => a > b ? a : b);
    final maxY = maxVal <= 0 ? 1.0 : maxVal * 1.15;
    final wide = days.length > 10;
    final labelEvery = wide ? 5 : 1;
    final semantics = days
        .map(
          (d) => d.hasLogs
              ? '${d.localDate}: ${Fmt.integer(value(d))} $unit'
              : '${d.localDate}: not logged',
        )
        .join(', ');
    return SizedBox(
      height: 190,
      child: Semantics(
        label: semantics,
        excludeSemantics: true,
        child: BarChart(
          BarChartData(
            minY: 0,
            maxY: maxY,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, _) {
                  final d = days[group.x];
                  return BarTooltipItem(
                    d.hasLogs ? '${Fmt.integer(rod.toY)} $unit' : 'Not logged',
                    Theme.of(context).textTheme.labelMedium!,
                  );
                },
              ),
            ),
            extraLinesData: ExtraLinesData(
              horizontalLines: [
                if (target > 0)
                  HorizontalLine(
                    y: target,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    strokeWidth: 1,
                    dashArray: [5, 4],
                  ),
              ],
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (v, meta) {
                    if (v != meta.max && v != 0 && v != target) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        Fmt.integer(v),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= days.length) {
                      return const SizedBox.shrink();
                    }
                    final fromEnd = days.length - 1 - i;
                    if (fromEnd % labelEvery != 0) {
                      return const SizedBox.shrink();
                    }
                    final d = LocalDates.parse(days[i].localDate);
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        wide
                            ? DateFormat.Md().format(d)
                            : DateFormat.E().format(d),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < days.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: days[i].hasLogs ? value(days[i]) : 0,
                      width: wide ? 6 : 18,
                      color: color,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
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
    final t = Theme.of(context).textTheme;
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
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      color: AppColors.brand,
                      barWidth: 3,
                      isCurved: false,
                      dotData: const FlDotData(show: true),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          'Sources: ${sources.join(', ')}',
          style: t.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
