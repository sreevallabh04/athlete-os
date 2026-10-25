import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/env.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../integrations/data/api_errors.dart';
import '../application/train_providers.dart';
import '../data/strava_sync_service.dart';
import '../domain/run_review.dart';
import '../domain/running_analytics.dart';
import '../domain/running_models.dart';
import 'widgets/hud_kit.dart';
import 'widgets/strava_branding.dart';

class ActivityDetailScreen extends ConsumerStatefulWidget {
  const ActivityDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ActivityDetailScreen> createState() =>
      _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends ConsumerState<ActivityDetailScreen> {
  bool _detailRequested = false;
  String? _detailError;

  /// Lazily fetch Strava splits/laps when a Strava run is opened without them.
  void _maybeFetchDetail(RunActivity a) {
    if (_detailRequested || !a.isStrava || a.splits.isNotEmpty) return;
    if (!Env.hasStrava) return;
    final status = ref.read(integrationStatusProvider(Providers.strava)).value;
    if (!isConnected(status)) return;
    _detailRequested = true;
    Future.microtask(() async {
      try {
        await ref.read(stravaSyncServiceProvider).fetchDetail(a.id);
      } on IntegrationException catch (e) {
        if (mounted) setState(() => _detailError = e.message);
      } catch (_) {
        if (mounted) setState(() => _detailError = 'Could not load splits.');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final deduped = ref.watch(cardioActivitiesProvider);
    final raw = ref.watch(rawCardioProvider).value ?? const <RunActivity>[];
    final today = ref.watch(todayKeyProvider);
    return deduped.when(
      loading: () => const AppPage(
        title: 'Activity',
        children: [ScanlineLoader(lines: 4)],
      ),
      error: (e, _) => const AppPage(
        title: 'Activity',
        children: [ErrorState(message: 'Could not load this activity.')],
      ),
      data: (all) {
        final a =
            all.where((x) => x.id == widget.id).firstOrNull ??
            raw.where((x) => x.id == widget.id).firstOrNull;
        if (a == null) {
          return const AppPage(
            title: 'Activity',
            children: [
              EmptyState(
                icon: Icons.search_off,
                title: 'Activity not found',
                message:
                    'It may have been deleted at the source, or removed '
                    'because cached Strava data expires after 7 days.',
              ),
            ],
          );
        }
        _maybeFetchDetail(a);
        final review = a.isRun ? reviewRun(a, all, todayKey: today) : null;
        return _Body(activity: a, review: review, detailError: _detailError);
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.activity,
    required this.review,
    required this.detailError,
  });
  final RunActivity activity;
  final RunReview? review;
  final String? detailError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = activity;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final stravaConnected =
        Env.hasStrava &&
        isConnected(
          ref.watch(integrationStatusProvider(Providers.strava)).value,
        );
    final full = fullKmSplits(a.splits);
    return AppPage(
      title: a.name ?? 'Activity',
      eyebrow:
          '${Fmt.weekdayDayMonth(a.startAt).toUpperCase()} · '
          '${Fmt.time(a.startAt).toUpperCase()}',
      children: [
        AppCard(
          accent: AppColors.running,
          brackets: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: HudReadout(
                      label: 'Distance',
                      value: a.distanceM == null
                          ? '—'
                          : (a.distanceM! / 1000).toStringAsFixed(2),
                      unit: 'km',
                      size: 44,
                    ),
                  ),
                  HudReadout(
                    label: 'Avg pace',
                    value: a.paceSPerKm == null
                        ? '—'
                        : Fmt.pace(a.paceSPerKm!).replaceAll(' /km', ''),
                    unit: '/km',
                    size: 28,
                    color: AppColors.running,
                    crossAxisAlignment: CrossAxisAlignment.end,
                  ),
                ],
              ),
              const HudDivider(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: HudReadout(
                      label: 'Moving',
                      value: a.movingTimeS == null
                          ? '—'
                          : Fmt.duration(a.movingTimeS!),
                      caption: a.elapsedTimeS == null
                          ? null
                          : 'elapsed ${Fmt.duration(a.elapsedTimeS!)}',
                      size: 20,
                    ),
                  ),
                  Expanded(
                    child: HudReadout(
                      label: 'Heart rate',
                      value: a.avgHr == null ? '—' : '${a.avgHr!.round()}',
                      unit: a.avgHr == null ? null : 'bpm',
                      caption: a.maxHr == null
                          ? null
                          : 'max ${a.maxHr!.round()}',
                      size: 20,
                      color: a.avgHr == null ? null : AppColors.heart,
                    ),
                  ),
                  Expanded(
                    child: HudReadout(
                      label: 'Elevation',
                      value: a.elevationGainM == null
                          ? '—'
                          : '${a.elevationGainM!.round()}',
                      unit: a.elevationGainM == null ? null : 'm',
                      size: 20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SourceBadge(origin: DataOrigin.fromKey(a.source)),
                  if (a.alsoInHealthConnect)
                    const HudTag('ALSO IN HEALTH CONNECT'),
                ],
              ),
            ],
          ),
        ),
        if (a.isStrava && a.externalId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: ViewOnStravaLink(stravaId: a.externalId!),
          ),
        if (detailError != null) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            message: 'Splits unavailable: $detailError',
            color: AppColors.warning,
          ),
        ],
        if (a.splits.isNotEmpty) ...[
          const SectionHeader(
            'Splits',
            subtitle: 'Taller = faster · gold = best',
            accent: AppColors.running,
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (full.length >= 2) ...[
                  _SplitsChart(splits: full),
                  const HudDivider(),
                ],
                _SplitsTable(splits: a.splits),
              ],
            ),
          ),
        ],
        _ChartsSection(activity: a, useStreams: a.isStrava && stravaConnected),
        if (review != null) ...[
          const SectionHeader('Post-run review'),
          _ReviewCard(review: review!),
        ],
        const SizedBox(height: AppSpacing.lg),
        _AiCoachButton(activity: a),
        if (a.isStrava) const PoweredByStrava(),
        const SizedBox(height: AppSpacing.sm),
        Text(
          a.isStrava
              ? 'Strava data is cached on this device for at most 7 days and '
                    'is never shared with AI.'
              : 'Source: ${DataOrigin.fromKey(a.source).label}.',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SplitsChart extends StatelessWidget {
  const _SplitsChart({required this.splits});
  final List<RunSplit> splits;

  @override
  Widget build(BuildContext context) {
    final paces = [for (final s in splits) s.paceSPerKm!];
    final fastest = paces.indexOf(paces.reduce((a, b) => a < b ? a : b));
    // Speed (km/h) so faster splits stand taller; tooltips show pace.
    final speeds = [for (final p in paces) 3600 / p];
    final lo = speeds.reduce((a, b) => a < b ? a : b);
    return HudBarChart(
      values: speeds,
      minY: (lo * 0.85).floorToDouble(),
      labels: [for (var i = 0; i < splits.length; i++) 'KM ${i + 1}'],
      color: AppColors.running,
      height: 150,
      colorFor: (i, _) => i == fastest
          ? AppColors.gold
          : AppColors.running.withValues(alpha: 0.75),
      semanticLabel: 'Pace per kilometre split chart',
      tooltip: (i, _) =>
          'KM ${i + 1} · ${Fmt.pace(paces[i]).replaceAll(' /km', '')}/km',
    );
  }
}

class _SplitsTable extends StatelessWidget {
  const _SplitsTable({required this.splits});
  final List<RunSplit> splits;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final head = hud.label(size: 10.5);
    final cell = hud.mono(size: 12, color: hud.text);
    final paces = [for (final s in fullKmSplits(splits)) s.paceSPerKm!];
    final fastest = paces.isEmpty
        ? null
        : paces.reduce((a, b) => a < b ? a : b);
    return Table(
      columnWidths: const {0: FixedColumnWidth(34)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            for (final h in ['KM', 'DIST', 'TIME', 'PACE', 'HR', 'ELEV'])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(h, style: head),
              ),
          ],
        ),
        for (var i = 0; i < splits.length; i++)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text('${i + 1}', style: hud.mono(size: 12)),
              ),
              Text(
                (splits[i].distanceM / 1000).toStringAsFixed(2),
                style: cell,
              ),
              Text(Fmt.duration(splits[i].movingTimeS), style: cell),
              Text(
                splits[i].paceSPerKm == null
                    ? '—'
                    : Fmt.pace(splits[i].paceSPerKm!).replaceAll(' /km', ''),
                style: cell.copyWith(
                  color: splits[i].paceSPerKm == fastest
                      ? AppColors.gold
                      : AppColors.running,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(splits[i].avgHr?.round().toString() ?? '—', style: cell),
              Text(
                splits[i].elevDiffM == null
                    ? '—'
                    : '${splits[i].elevDiffM! >= 0 ? '+' : '−'}'
                          '${splits[i].elevDiffM!.abs().round()}',
                style: cell,
              ),
            ],
          ),
      ],
    );
  }
}

/// HR and elevation charts. Strava streams are fetched on demand (never
/// stored); otherwise per-split values are used when present.
class _ChartsSection extends ConsumerWidget {
  const _ChartsSection({required this.activity, required this.useStreams});
  final RunActivity activity;
  final bool useStreams;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (useStreams) {
      final streams = ref.watch(stravaStreamsProvider(activity.id));
      return streams.when(
        loading: () => const Padding(
          padding: EdgeInsets.only(top: AppSpacing.lg),
          child: ScanlineLoader(height: 120, lines: 0),
        ),
        error: (e, _) => _fromSplits(context),
        data: (s) {
          final dist = s['distance'];
          final hr = s['heartrate'];
          final alt = s['altitude'];
          if (dist == null || (hr == null && alt == null)) {
            return _fromSplits(context);
          }
          (List<double>, List<double>) series(List<double> ys) {
            final n = ys.length < dist.length ? ys.length : dist.length;
            final step = (n / 200).ceil().clamp(1, 1 << 20);
            final xs = <double>[], vs = <double>[];
            for (var i = 0; i < n; i += step) {
              if (ys[i].isFinite && dist[i].isFinite) {
                xs.add(dist[i] / 1000);
                vs.add(ys[i]);
              }
            }
            return (xs, vs);
          }

          Widget chart(
            String title,
            String sub,
            List<double> ys,
            Color c,
            String unit,
          ) {
            final (xs, vs) = series(ys);
            if (vs.length < 2) return const SizedBox.shrink();
            return Column(
              children: [
                SectionHeader(title, subtitle: sub, accent: c),
                AppCard(
                  child: HudLineChart(
                    values: vs,
                    color: c,
                    curved: false,
                    semanticLabel: '$title over distance',
                    format: (v) => v.toStringAsFixed(0),
                    xLabel: (i) => '${xs[i].toStringAsFixed(1)} km',
                    tooltip: (i) =>
                        '${xs[i].toStringAsFixed(2)} km · '
                        '${vs[i].round()} $unit',
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              if (hr != null && hr.isNotEmpty)
                chart('Heart rate', 'bpm vs km', hr, AppColors.heart, 'bpm'),
              if (alt != null && alt.isNotEmpty)
                chart('Elevation', 'm vs km', alt, AppColors.habit, 'm'),
            ],
          );
        },
      );
    }
    return _fromSplits(context);
  }

  Widget _fromSplits(BuildContext context) {
    final splits = activity.splits;
    final hr = <double>[];
    final hrKm = <int>[];
    for (var i = 0; i < splits.length; i++) {
      if (splits[i].avgHr != null) {
        hr.add(splits[i].avgHr!);
        hrKm.add(i + 1);
      }
    }
    var cum = 0.0;
    final elev = <double>[0];
    for (var i = 0; i < splits.length; i++) {
      if (splits[i].elevDiffM == null) continue;
      cum += splits[i].elevDiffM!;
      elev.add(cum);
    }
    return Column(
      children: [
        if (hr.length >= 2) ...[
          const SectionHeader(
            'Heart rate',
            subtitle: 'Average per split',
            accent: AppColors.heart,
          ),
          AppCard(
            child: HudLineChart(
              values: hr,
              color: AppColors.heart,
              height: 150,
              semanticLabel: 'Average heart rate per split',
              format: (v) => v.toStringAsFixed(0),
              xLabel: (i) => 'KM ${hrKm[i]}',
              tooltip: (i) => 'KM ${hrKm[i]} · ${hr[i].round()} bpm',
            ),
          ),
        ],
        if (elev.length >= 3) ...[
          const SectionHeader(
            'Elevation',
            subtitle: 'Cumulative, metres',
            accent: AppColors.habit,
          ),
          AppCard(
            child: HudLineChart(
              values: elev,
              color: AppColors.habit,
              height: 130,
              semanticLabel: 'Cumulative elevation change per split',
              format: (v) => v.toStringAsFixed(0),
              xLabel: (i) => 'KM $i',
              tooltip: (i) =>
                  'KM $i · ${elev[i] >= 0 ? '+' : '−'}${elev[i].abs().round()} m',
            ),
          ),
        ],
      ],
    );
  }
}

/// The on-device review. Deterministic rules only — no AI is involved, which
/// is what Strava's API terms require for Strava activities.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});
  final RunReview review;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: hud.accent),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(text, style: t.bodyMedium)),
        ],
      ),
    );
    final split = review.splitComparison;
    final drift = review.hrDrift;
    final sim = review.similar;
    return AppCard(
      semanticLabel: kReviewLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlowIcon(Icons.rule, size: 16, color: hud.accent),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  kReviewLabel,
                  style: t.labelMedium?.copyWith(color: hud.accentInk),
                ),
              ),
              const HudTag('NO AI'),
            ],
          ),
          const HudDivider(),
          line(Icons.summarize_outlined, review.summary),
          if (review.paceConsistency != null)
            line(Icons.timeline, review.paceConsistency!),
          if (split != null)
            line(
              Icons.compare_arrows,
              '${split.pattern.label}: first half '
              '${Fmt.pace(split.firstHalfPace)}, second half '
              '${Fmt.pace(split.secondHalfPace)}.',
            ),
          if (drift != null)
            line(
              Icons.favorite_border,
              'Heart-rate drift ${(drift.driftFraction * 100).toStringAsFixed(1)}% '
              '(${drift.firstHalfHr.round()} → ${drift.secondHalfHr.round()} bpm).',
            ),
          if (sim != null)
            line(
              Icons.history,
              '${(sim.paceDeltaFraction.abs() * 100).toStringAsFixed(1)}% '
              '${sim.paceDeltaFraction <= 0 ? 'faster' : 'slower'} than your '
              'last ${sim.count} similar run(s) '
              '(avg ${Fmt.pace(sim.avgPaceSPerKm)}).',
            )
          else
            line(Icons.history, 'No earlier runs within ±20% distance yet.'),
          GlassPanel(
            accent: AppColors.running,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SUGGESTED NEXT',
                  style: hud.label(size: 11, color: AppColors.running),
                ),
                const SizedBox(height: 2),
                Text(
                  '${review.next.type.label}: ${review.next.description}',
                  style: t.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  review.next.rationale,
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('TAKEAWAY', style: hud.label(size: 11)),
          const SizedBox(height: 2),
          Text(review.takeaway, style: t.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          Text(
            review.uncertainty,
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
    );
  }
}

class _AiCoachButton extends StatelessWidget {
  const _AiCoachButton({required this.activity});
  final RunActivity activity;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    if (a.isStrava) {
      // Strava API Policy §5.3: no Strava data (or derivatives) may be used
      // with AI, so the button is disabled with an explanation.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HudButton.secondary(
            label: 'Ask AI coach for a deeper review',
            icon: Icons.block,
            expand: true,
            onPressed: null,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Unavailable for Strava activities: Strava\'s API terms prohibit '
            'sharing Strava data with AI. The review above is computed on '
            'this device without AI.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          if (a.alsoInHealthConnect && a.duplicateIds.isNotEmpty)
            HudButton.ghost(
              label: 'Open the Health Connect copy of this run',
              icon: Icons.open_in_new,
              onPressed: () =>
                  context.push('/running/activity/${a.duplicateIds.first}'),
            ),
        ],
      );
    }
    final date = Fmt.weekdayDayMonth(a.startAt);
    return HudButton.secondary(
      label: 'Ask AI coach for a deeper review',
      icon: Icons.auto_awesome,
      expand: true,
      onPressed: () => context.push(
        '/coach?prompt=${Uri.encodeComponent('Review my run on $date (activity ${a.id})')}',
      ),
    );
  }
}
