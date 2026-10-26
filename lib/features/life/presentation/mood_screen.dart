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
import '../domain/habit_models.dart';
import '../domain/mood_stats.dart';
import 'mood_check_in_sheet.dart';
import 'widgets/habit_widgets.dart' show MonthSwitcher;
import 'widgets/life_widgets.dart';
import 'widgets/mood_orb.dart';

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
      eyebrow: 'PRIVATE CHECK-INS · ON THIS DEVICE',
      bottomAction: HudButton(
        expand: true,
        label: 'Check in',
        icon: Icons.add_reaction_outlined,
        onPressed: () => showMoodCheckIn(context),
      ),
      children: [
        today.when(
          loading: () => const ScanlineLoader(height: 150, lines: 0),
          error: (e, _) =>
              const ErrorState(message: 'Today\'s check-in couldn\'t load.'),
          data: (e) => _TodayHero(entry: e),
        ),
        const LifeSection(
          'Trend',
          hint: 'Daily average mood · drag to scrub',
          accent: AppColors.mood,
        ),
        SegmentedHud<int>(
          segments: const [
            HudSegment(value: 30, label: '30 days'),
            HudSegment(value: 90, label: '90 days'),
          ],
          value: _days,
          onChanged: (v) => setState(() => _days = v),
        ),
        const SizedBox(height: AppSpacing.md),
        insights.when(
          skipLoadingOnReload: true,
          loading: () =>
              const AppCard(child: ScanlineLoader(height: 180, lines: 0)),
          error: (e, _) => const AppCard(
            child: ErrorState(message: 'The trend couldn\'t be calculated.'),
          ),
          data: (i) => AppCard(child: MoodTrendChart(insights: i)),
        ),
        const SectionHeader('Patterns'),
        insights.when(
          skipLoadingOnReload: true,
          loading: () => const SizedBox.shrink(),
          error: (e, _) => const SizedBox.shrink(),
          data: (i) => AppCard(child: _Correlations(insights: i)),
        ),
        const LifeSection('Calendar', hint: 'Average mood per day'),
        AppCard(
          child: MonthSwitcher(
            month: _month,
            maxMonth: DateTime(now.year, now.month),
            onChanged: (m) => setState(() => _month = m),
            builder: (context) => _MoodMonthGrid(month: _month, now: now),
          ),
        ),
        const SectionHeader('Recent check-ins'),
        recent.when(
          loading: () => const ScanlineLoader(lines: 3),
          error: (e, _) =>
              const ErrorState(message: 'Check-ins couldn\'t be loaded.'),
          data: (entries) => entries.isEmpty
              ? const EmptyState(
                  compact: true,
                  icon: Icons.history,
                  color: AppColors.mood,
                  title: 'No check-ins yet',
                )
              : StaggeredList(
                  gap: AppSpacing.sm,
                  children: [
                    for (final e in entries.take(20))
                      MoodEntryCard(
                        key: ValueKey(e.id),
                        entry: e,
                        now: now,
                        deletable: true,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 96),
      ],
    );
  }
}

class _TodayHero extends StatelessWidget {
  const _TodayHero({required this.entry});
  final MoodEntry? entry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final e = entry;
    if (e == null) {
      return AppCard(
        accent: AppColors.mood,
        brackets: true,
        child: Column(
          children: [
            const Hero(
              tag: 'life-mood-orb',
              child: MoodOrb(mood: null, size: 112),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('STANDBY', style: hud.mono(size: 10.5)),
            const SizedBox(height: 2),
            Text('No check-in yet today', style: t.titleMedium),
            Text(
              'It takes about ten seconds.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
            const SizedBox(height: AppSpacing.md),
            MoodPicker(
              value: null,
              size: 36,
              onChanged: (m) => showMoodCheckIn(context, initialMood: m),
            ),
          ],
        ),
      );
    }
    final tags = moodTagsOf(e);
    return AppCard(
      accent: moodColor(e.mood),
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Hero(
                tag: 'life-mood-orb',
                child: MoodOrb(mood: e.mood.toDouble(), size: 104),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('LATEST TODAY', style: hud.label(size: 11)),
                    const SizedBox(height: 2),
                    Text(moodLabels[e.mood]!, style: t.headlineSmall),
                    Text(Fmt.time(e.recordedAt), style: hud.mono(size: 12)),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.sm,
                      children: [
                        MiniLevel(
                          label: 'ENERGY',
                          value: e.energy,
                          color: AppColors.calories,
                          valueLabel: energyLabels[e.energy],
                        ),
                        MiniLevel(
                          label: 'STRESS',
                          value: e.stress,
                          color: AppColors.info,
                          valueLabel: stressLabels[e.stress],
                        ),
                        MiniLevel(
                          label: 'SLEEP',
                          value: e.sleepQuality,
                          color: AppColors.sleep,
                          valueLabel: sleepQualityLabels[e.sleepQuality],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (tags.isNotEmpty || e.note != null) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final tag in tags) TagPill(tag, color: AppColors.mood),
              ],
            ),
            if (e.note != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(e.note!, style: t.bodyMedium),
            ],
          ],
        ],
      ),
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
    final hud = context.hud;
    final tags = moodTagsOf(entry);
    final chips = <String>[
      if (entry.energy != null) 'Energy: ${energyLabels[entry.energy]}',
      if (entry.stress != null) 'Stress: ${stressLabels[entry.stress]}',
      if (entry.sleepQuality != null)
        'Sleep: ${sleepQualityLabels[entry.sleepQuality]}',
    ];
    return AppCard(
      semanticLabel: 'Mood ${moodLabels[entry.mood]}',
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MoodOrb(mood: entry.mood.toDouble(), size: 44, bezel: false),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(title!.toUpperCase(), style: hud.label(size: 10.5)),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        moodLabels[entry.mood]!,
                        style: t.titleMedium,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '${DateFormat('EEE d MMM').format(entry.recordedAt.toLocal()).toUpperCase()} · '
                      '${DateFormat('HH:mm').format(entry.recordedAt.toLocal())}',
                      style: hud.mono(size: 10.5),
                    ),
                  ],
                ),
                if (chips.isNotEmpty || tags.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs + 2),
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
                  const SizedBox(height: AppSpacing.xs + 2),
                  Text(entry.note!, style: t.bodyMedium),
                ],
              ],
            ),
          ),
          if (deletable)
            IconButton(
              tooltip: 'Delete check-in',
              icon: Icon(Icons.delete_outline, color: hud.textMuted, size: 20),
              onPressed: () async {
                final ok = await confirmHud(
                  context,
                  title: 'Delete this check-in?',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (ok) {
                  await ref.read(moodRepositoryProvider).delete(entry.id);
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Daily mean mood line (gradient from the low-mood slate to the high-mood
/// gold) with a dashed average and a scrubbable HUD tooltip.
class MoodTrendChart extends StatefulWidget {
  const MoodTrendChart({super.key, required this.insights});
  final MoodInsights insights;

  @override
  State<MoodTrendChart> createState() => _MoodTrendChartState();
}

class _MoodTrendChartState extends State<MoodTrendChart> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final insights = widget.insights;
    final trend = insights.trend;
    final points = trend.where((p) => p.$2 != null).length;
    if (points < 2) {
      return EmptyState(
        compact: true,
        icon: Icons.show_chart,
        color: AppColors.mood,
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
    final base = HudChartStyle.line(spots, AppColors.mood, width: 2);
    final lastX = spots.lastWhere((p) => !p.isNull()).x;
    final small = insights.days <= 30;
    final bar = base.copyWith(
      curveSmoothness: 0.35,
      // Small dots on real check-ins only; the latest one is highlighted.
      dotData: FlDotData(
        checkToShowDot: (spot, _) =>
            !spot.isNull() && (small || spot.x == lastX),
        getDotPainter: (spot, _, _, _) {
          final c = moodColorAt(spot.y);
          return spot.x == lastX
              ? FlDotCirclePainter(
                  radius: 4,
                  color: Color.lerp(c, Colors.white, 0.7)!,
                  strokeWidth: 2,
                  strokeColor: c,
                )
              : FlDotCirclePainter(radius: 2.5, color: c, strokeWidth: 0);
        },
      ),
      gradient: const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: moodScaleColors,
      ),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.mood.withValues(alpha: 0.18),
            AppColors.mood.withValues(alpha: 0),
          ],
        ),
      ),
    );
    String labelFor(double v) => switch (v.round()) {
      1 => 'V.LOW',
      3 => 'OKAY',
      5 => 'GREAT',
      _ => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Average',
                value: avg.toStringAsFixed(1),
                sub: moodLabels[avg.round().clamp(1, 5)],
                color: AppColors.mood,
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'Days logged',
                value: '$points/${insights.days}',
                sub: '${insights.entryCount} check-ins',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          label:
              'Mood trend chart over ${insights.days} days, average '
              '${avg.toStringAsFixed(1)} out of 5',
          excludeSemantics: true,
          child: SizedBox(
            height: 190,
            child: LineChart(
              LineChartData(
                minY: 0.8,
                maxY: 5.2,
                minX: 0,
                maxX: (trend.length - 1).toDouble(),
                clipData: const FlClipData.horizontal(),
                gridData: HudChartStyle.grid(context, interval: 1),
                borderData: HudChartStyle.noBorder,
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: avg,
                      color: AppColors.mood.withValues(alpha: 0.5),
                      strokeWidth: 1,
                      dashArray: const [4, 4],
                    ),
                  ],
                ),
                titlesData: HudChartStyle.titles(
                  context,
                  leftReserved: 44,
                  leftInterval: 1,
                  left: (v, meta) {
                    if (v != v.roundToDouble()) return const SizedBox.shrink();
                    return Text(
                      labelFor(v),
                      style: HudChartStyle.axisLabel(context),
                    );
                  },
                  bottomInterval: (trend.length / 4).floorToDouble().clamp(
                    1,
                    60,
                  ),
                  bottom: (v, meta) {
                    final i = v.toInt();
                    final step = (trend.length / 4).floor().clamp(1, 60);
                    if (i < 0 ||
                        i >= trend.length ||
                        v != v.roundToDouble() ||
                        i % step != 0) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        DateFormat('d MMM')
                            .format(LocalDates.parse(trend[i].$1))
                            .toUpperCase(),
                        style: HudChartStyle.axisLabel(context),
                      ),
                    );
                  },
                ),
                lineTouchData:
                    HudChartStyle.lineTouch(
                      context,
                      format: (s) {
                        final i = s.x.toInt();
                        final d = DateFormat('EEE d MMM')
                            .format(LocalDates.parse(trend[i].$1));
                        return '$d\n${moodLabels[s.y.round().clamp(1, 5)]} · '
                            '${s.y.toStringAsFixed(1)}';
                      },
                    ).copyWith(
                      touchCallback: (event, response) {
                        final i = response?.lineBarSpots?.firstOrNull?.x
                            .toInt();
                        if (i != null && i != _touched) {
                          Haptics.selection();
                        }
                        _touched = i;
                      },
                    ),
                lineBarsData: [bar],
              ),
              duration: AppMotion.reduced(context)
                  ? Duration.zero
                  : AppMotion.long,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Gaps are days without a check-in — nothing is filled in.',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
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
    final hud = context.hud;
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Divider(height: 1, color: hud.hairline.withValues(alpha: 0.12)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.visibility_outlined, size: 14, color: hud.textMuted),
            const SizedBox(width: 6),
            Text('OBSERVATION, NOT CAUSATION', style: hud.label(size: 11)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'These show how things moved together over the last '
          '${insights.days} days. They can\'t tell you what causes what. '
          'A coefficient (r) is only shown with at least '
          '$minCorrelationSample days of data.',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
        divider(),
        _CorrelationRow(
          icon: Icons.bedtime_outlined,
          title: 'Mood vs sleep quality',
          source: 'Your check-in ratings',
          result: insights.moodVsSleepQuality,
        ),
        divider(),
        if (insights.moodVsSleepMinutes == null)
          const _CorrelationRow(
            icon: Icons.timelapse,
            title: 'Mood vs sleep duration',
            source: 'Health Connect',
            unavailable: 'No sleep duration data has been synced.',
          )
        else
          _CorrelationRow(
            icon: Icons.timelapse,
            title: 'Mood vs sleep duration',
            source: 'Synced sleep minutes',
            result: insights.moodVsSleepMinutes,
          ),
        divider(),
        _CorrelationRow(
          icon: Icons.fitness_center,
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
    required this.icon,
    required this.title,
    required this.source,
    this.result,
    this.unavailable,
    this.binary = false,
  });
  final IconData icon;
  final String title;
  final String source;
  final CorrelationResult? result;
  final String? unavailable;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final r = result;
    String body;
    final hasR =
        unavailable == null &&
        r != null &&
        r.status != CorrelationStatus.notEnoughData &&
        r.status != CorrelationStatus.noVariation &&
        r.r != null;
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
    final progress =
        unavailable == null &&
            r != null &&
            r.status == CorrelationStatus.notEnoughData
        ? (r.n / minCorrelationSample).clamp(0.0, 1.0)
        : null;
    return Semantics(
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: hud.textMuted),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                const SizedBox(height: 2),
                Text(body, style: t.bodyMedium),
                if (extra != null)
                  Text(
                    extra,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                const SizedBox(height: AppSpacing.sm),
                if (hasR)
                  _RMeter(r: r.r!)
                else if (progress != null)
                  MetricBar(
                    label: 'Data collected',
                    value: r!.n.toDouble(),
                    target: minCorrelationSample.toDouble(),
                    color: hud.accent,
                    unit: ' days',
                    segments: minCorrelationSample,
                  ),
                const SizedBox(height: 4),
                Text(
                  'SOURCE · ${source.toUpperCase()}',
                  style: hud.mono(size: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Diverging −1…+1 meter: a centre tick, the bar grows left (inverse) or
/// right (together). Neutral colours — a correlation is not good or bad.
class _RMeter extends StatelessWidget {
  const _RMeter({required this.r});
  final double r;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 10,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: r.clamp(-1.0, 1.0)),
            duration: reduced ? Duration.zero : AppMotion.data,
            curve: AppMotion.emphasizedDecelerate,
            builder: (context, v, _) => CustomPaint(
              painter: _RMeterPainter(v: v, hud: hud),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text('−1 INVERSE', style: hud.label(size: 9.5)),
            const Spacer(),
            Text('0', style: hud.label(size: 9.5)),
            const Spacer(),
            Text('TOGETHER +1', style: hud.label(size: 9.5)),
          ],
        ),
      ],
    );
  }
}

class _RMeterPainter extends CustomPainter {
  _RMeterPainter({required this.v, required this.hud});
  final double v;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    final h = 6.0;
    final top = (size.height - h) / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, size.width, h),
        const Radius.circular(3),
      ),
      Paint()..color = hud.hairline.withValues(alpha: hud.isDark ? 0.1 : 0.16),
    );
    final w = mid * v.abs();
    final rect = v >= 0
        ? Rect.fromLTWH(mid, top, w, h)
        : Rect.fromLTWH(mid - w, top, w, h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = hud.accent.withValues(alpha: 0.85),
    );
    canvas.drawLine(
      Offset(mid, 0),
      Offset(mid, size.height),
      Paint()
        ..color = hud.text.withValues(alpha: 0.5)
        ..strokeWidth = 1.2,
    );
    final head = Offset(v >= 0 ? mid + w : mid - w, size.height / 2);
    canvas.drawCircle(
      head,
      4,
      Paint()..color = Color.lerp(hud.accent, Colors.white, 0.6)!,
    );
  }

  @override
  bool shouldRepaint(_RMeterPainter old) => old.v != v || old.hud != hud;
}

class _MoodMonthGrid extends ConsumerWidget {
  const _MoodMonthGrid({required this.month, required this.now});
  final DateTime month;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final entries =
        ref.watch(moodMonthProvider(LocalDates.key(first))).value ??
        const <MoodEntry>[];
    final daily = dailyMoodMeans(entries.map(moodPointOf));
    final today = LocalDates.key(now);
    final leading = first.weekday - 1;
    final rows = ((leading + daysInMonth) / 7).ceil();
    return LayoutBuilder(
      builder: (context, box) {
        final cellW = box.maxWidth / 7;
        final cellH = cellW.clamp(0.0, 46.0);
        Widget cell(int index) {
          final d = index - leading + 1;
          if (d < 1 || d > daysInMonth) {
            return SizedBox(width: cellW, height: cellH);
          }
          final key = LocalDates.key(DateTime(month.year, month.month, d));
          final mean = daily[key];
          final future = key.compareTo(today) > 0;
          Widget face;
          if (mean == null) {
            face = Center(
              child: Text(
                '$d',
                style: t.labelMedium?.copyWith(
                  color: hud.textMuted.withValues(alpha: future ? 0.4 : 0.8),
                ),
              ),
            );
          } else {
            final c = moodColorAt(mean);
            face = DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  colors: [
                    Color.lerp(c, Colors.white, 0.3)!,
                    c.withValues(alpha: 0.75),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: c.withValues(alpha: 0.35 * hud.glowStrength),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '$d',
                  style: t.labelMedium?.copyWith(
                    color: AppColors.darkBg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          }
          if (key == today) {
            face = HudFrame(
              color: hud.accent,
              cornerLength: 6,
              inset: -1,
              child: face,
            );
          }
          return SizedBox(
            width: cellW,
            height: cellH,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Semantics(
                label:
                    '${DateFormat('d MMMM').format(LocalDates.parse(key))}: '
                    '${mean == null ? 'no check-in' : 'average mood ${mean.toStringAsFixed(1)}'}',
                excludeSemantics: true,
                child: face,
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (final l in weekdayLetter)
                  SizedBox(
                    width: cellW,
                    child: Center(child: Text(l, style: hud.label(size: 11))),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var r = 0; r < rows; r++)
              Row(children: [for (var i = 0; i < 7; i++) cell(r * 7 + i)]),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                for (var m = 1; m <= 5; m++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: moodColor(m),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        moodLabels[m]!.toUpperCase(),
                        style: hud.label(size: 9.5),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
