import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/mood_journal_providers.dart';
import '../data/mood_repository.dart';
import '../domain/mood_stats.dart';
import 'mood_check_in_sheet.dart';
import 'widgets/life_widgets.dart';

class MoodScreen extends ConsumerStatefulWidget {
  const MoodScreen({super.key});

  @override
  ConsumerState<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends ConsumerState<MoodScreen> {
  int _days = 30;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider).now();
    _month = DateTime(now.year, now.month);
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayMoodProvider);
    final insights = ref.watch(moodInsightsProvider(_days));
    final recent = ref.watch(moodEntriesProvider(90));
    final now = ref.watch(clockProvider).now();
    return AppPage(
      title: 'Mood',
      subtitle: 'Private check-ins, stored only on this device.',
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'mood-check-in',
        onPressed: () => showMoodCheckIn(context),
        icon: const Icon(Icons.add_reaction_outlined),
        label: const Text('Check in'),
      ),
      children: [
        const SizedBox(height: AppSpacing.md),
        today.when(
          loading: () => const LoadingState(),
          error: (e, _) =>
              const ErrorState(message: 'Today\'s check-in couldn\'t load.'),
          data: (e) => e == null
              ? AppCard(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.mood_outlined,
                    title: 'No check-in yet today',
                    message: 'It takes about ten seconds.',
                    actionLabel: 'Check in',
                    onAction: () => showMoodCheckIn(context),
                  ),
                )
              : MoodEntryCard(entry: e, now: now, title: 'Latest today'),
        ),
        const SectionHeader('Trend', subtitle: 'Daily average mood'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 90, label: Text('90 days')),
          ],
          selected: {_days},
          onSelectionChanged: (s) => setState(() => _days = s.first),
        ),
        const SizedBox(height: AppSpacing.md),
        insights.when(
          loading: () => const AppCard(child: LoadingState()),
          error: (e, _) => const AppCard(
            child: ErrorState(message: 'The trend couldn\'t be calculated.'),
          ),
          data: (i) => AppCard(child: MoodTrendChart(insights: i)),
        ),
        const SectionHeader(
          'Patterns',
          subtitle: 'Observations, not causation',
        ),
        insights.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => const SizedBox.shrink(),
          data: (i) => AppCard(child: _Correlations(insights: i)),
        ),
        SectionHeader(
          DateFormat('MMMM yyyy').format(_month),
          subtitle: 'History',
        ),
        recent.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => const SizedBox.shrink(),
          data: (entries) => AppCard(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous month',
                      onPressed: () => setState(
                        () => _month = DateTime(_month.year, _month.month - 1),
                      ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Next month',
                      onPressed:
                          DateTime(_month.year, _month.month + 1).isAfter(now)
                          ? null
                          : () => setState(
                              () => _month = DateTime(
                                _month.year,
                                _month.month + 1,
                              ),
                            ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                _MoodMonthGrid(month: _month, now: now),
              ],
            ),
          ),
        ),
        const SectionHeader('Recent check-ins'),
        recent.when(
          loading: () => const LoadingState(),
          error: (e, _) =>
              const ErrorState(message: 'Check-ins couldn\'t be loaded.'),
          data: (entries) => entries.isEmpty
              ? const EmptyState(
                  compact: true,
                  icon: Icons.history,
                  title: 'No check-ins yet',
                )
              : Column(
                  children: spaced([
                    for (final e in entries.take(20))
                      MoodEntryCard(entry: e, now: now, deletable: true),
                  ], gap: AppSpacing.sm),
                ),
        ),
      ],
    );
  }
}

class MoodEntryCard extends ConsumerWidget {
  const MoodEntryCard({
    super.key,
    required this.entry,
    required this.now,
    this.title,
    this.deletable = false,
  });
  final MoodEntry entry;
  final DateTime now;
  final String? title;
  final bool deletable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tags = moodTagsOf(entry);
    final chips = <String>[
      if (entry.energy != null) 'Energy: ${energyLabels[entry.energy]}',
      if (entry.stress != null) 'Stress: ${stressLabels[entry.stress]}',
      if (entry.sleepQuality != null)
        'Sleep: ${sleepQualityLabels[entry.sleepQuality]}',
    ];
    return AppCard(
      semanticLabel: 'Mood ${moodLabels[entry.mood]}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(moodIcon(entry.mood), size: 40, color: moodColor(entry.mood)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: t.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                Text(moodLabels[entry.mood]!, style: t.titleMedium),
                Text(
                  '${Fmt.weekdayDayMonth(entry.recordedAt)} · '
                  '${Fmt.time(entry.recordedAt)}',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (chips.isNotEmpty || tags.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final c in chips) TagPill(c),
                      for (final tag in tags)
                        TagPill(tag, color: AppColors.mood),
                    ],
                  ),
                ],
                if (entry.note != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(entry.note!, style: t.bodyMedium),
                ],
              ],
            ),
          ),
          if (deletable)
            IconButton(
              tooltip: 'Delete check-in',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete this check-in?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await ref.read(moodRepositoryProvider).delete(entry.id);
                }
              },
            ),
        ],
      ),
    );
  }
}

class MoodTrendChart extends StatelessWidget {
  const MoodTrendChart({super.key, required this.insights});
  final MoodInsights insights;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final trend = insights.trend;
    final points = trend.where((p) => p.$2 != null).length;
    if (points < 2) {
      return EmptyState(
        compact: true,
        icon: Icons.show_chart,
        title: 'Not enough check-ins yet',
        message: points == 0
            ? 'No check-ins in the last ${insights.days} days.'
            : 'A trend appears after check-ins on at least two days.',
      );
    }
    final spots = [
      for (var i = 0; i < trend.length; i++)
        trend[i].$2 == null
            ? FlSpot.nullSpot
            : FlSpot(i.toDouble(), trend[i].$2!),
    ];
    final values = [for (final p in trend) ?p.$2];
    final avg = values.reduce((a, b) => a + b) / values.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Average ${avg.toStringAsFixed(1)} · $points of ${insights.days} days '
          'with a check-in',
          style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Semantics(
          label:
              'Mood trend chart over ${insights.days} days, average '
              '${avg.toStringAsFixed(1)} out of 5',
          excludeSemantics: true,
          child: SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                minY: 1,
                maxY: 5,
                minX: 0,
                maxX: (trend.length - 1).toDouble(),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: 1,
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
                      interval: 1,
                      reservedSize: 28,
                      getTitlesWidget: (v, meta) =>
                          Text('${v.toInt()}', style: t.labelSmall),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: (trend.length / 4).floorToDouble().clamp(1, 60),
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (i < 0 || i >= trend.length) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          DateFormat('d MMM')
                              .format(LocalDates.parse(trend[i].$1)),
                          style: t.labelSmall,
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: AppColors.mood,
                    barWidth: 3,
                    isCurved: false,
                    dotData: FlDotData(show: insights.days <= 30),
                    belowBarData: BarAreaData(
                      show: true,
                      color: AppColors.mood.withValues(alpha: 0.10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Correlations extends StatelessWidget {
  const _Correlations({required this.insights});
  final MoodInsights insights;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These show how things moved together over the last '
          '${insights.days} days. They can\'t tell you what causes what. '
          'A coefficient (r) is only shown with at least '
          '$minCorrelationSample days of data.',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const Divider(height: AppSpacing.xl),
        _CorrelationRow(
          title: 'Mood vs sleep quality',
          source: 'Your check-in ratings',
          result: insights.moodVsSleepQuality,
        ),
        const Divider(height: AppSpacing.xl),
        if (insights.moodVsSleepMinutes == null)
          const _CorrelationRow(
            title: 'Mood vs sleep duration',
            source: 'Health Connect',
            unavailable: 'No sleep duration data has been synced.',
          )
        else
          _CorrelationRow(
            title: 'Mood vs sleep duration',
            source: 'Synced sleep minutes',
            result: insights.moodVsSleepMinutes,
          ),
        const Divider(height: AppSpacing.xl),
        _CorrelationRow(
          title: 'Mood on workout days vs other days',
          source: 'Logged workouts',
          result: insights.moodVsWorkout,
          binary: true,
        ),
      ],
    );
  }
}

class _CorrelationRow extends StatelessWidget {
  const _CorrelationRow({
    required this.title,
    required this.source,
    this.result,
    this.unavailable,
    this.binary = false,
  });
  final String title;
  final String source;
  final CorrelationResult? result;
  final String? unavailable;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final r = result;
    String body;
    if (unavailable != null) {
      body = unavailable!;
    } else if (r == null || r.status == CorrelationStatus.notEnoughData) {
      body =
          'Not enough data yet (${r?.n ?? 0} of $minCorrelationSample days '
          'needed).';
    } else if (r.status == CorrelationStatus.noVariation) {
      body = 'No variation yet across ${r.n} days, so no pattern to show.';
    } else {
      body =
          'r = ${r.r!.toStringAsFixed(2)} (${r.strengthLabel}) · '
          'n = ${r.n} days';
    }
    final extra =
        binary &&
            r != null &&
            r.status != CorrelationStatus.notEnoughData &&
            r.meanWith != null &&
            r.meanWithout != null
        ? 'Average mood ${r.meanWith!.toStringAsFixed(1)} on ${r.nWith} '
              'workout days vs ${r.meanWithout!.toStringAsFixed(1)} on '
              '${r.nWithout} other days.'
        : null;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 2),
          Text(body, style: t.bodyMedium),
          if (extra != null) Text(extra, style: t.bodySmall),
          Text(
            'Source: $source',
            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MoodMonthGrid extends ConsumerWidget {
  const _MoodMonthGrid({required this.month, required this.now});
  final DateTime month;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final entries =
        ref.watch(moodMonthProvider(LocalDates.key(first))).value ??
        const <MoodEntry>[];
    return Builder(
      builder: (context) {
        final daily = dailyMoodMeans(entries.map(moodPointOf));
        final today = LocalDates.key(now);
        final cells = <Widget>[
          for (final l in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
            Center(
              child: Text(
                l,
                style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (var i = 0; i < first.weekday - 1; i++) const SizedBox.shrink(),
        ];
        for (var d = 1; d <= daysInMonth; d++) {
          final key = LocalDates.key(DateTime(month.year, month.month, d));
          final mean = daily[key];
          cells.add(
            Semantics(
              label:
                  '${DateFormat('d MMMM').format(LocalDates.parse(key))}: '
                  '${mean == null ? 'no check-in' : 'average mood ${mean.toStringAsFixed(1)}'}',
              excludeSemantics: true,
              child: Container(
                margin: const EdgeInsets.all(2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: mean == null
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : moodColorFor(mean).withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: key == today
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                child: Text(
                  '$d',
                  style: t.labelMedium?.copyWith(
                    color: mean == null
                        ? scheme.onSurfaceVariant
                        : Colors.black,
                  ),
                ),
              ),
            ),
          );
        }
        return GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: cells,
        );
      },
    );
  }
}
