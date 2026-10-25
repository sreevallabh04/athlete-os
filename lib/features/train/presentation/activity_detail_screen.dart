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
import 'widgets/charts.dart';
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
      loading: () =>
          const AppPage(title: 'Activity', children: [LoadingState()]),
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
    final scheme = Theme.of(context).colorScheme;
    final stravaConnected =
        Env.hasStrava &&
        isConnected(
          ref.watch(integrationStatusProvider(Providers.strava)).value,
        );
    final full = fullKmSplits(a.splits);
    return AppPage(
      title: a.name ?? 'Activity',
      subtitle: '${Fmt.weekdayDayMonth(a.startAt)} · ${Fmt.time(a.startAt)}',
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            SourceBadge(origin: DataOrigin.fromKey(a.source), asOf: null),
            if (a.alsoInHealthConnect)
              const Chip(
                label: Text('also in Health Connect'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          accent: AppColors.running,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: 'Distance',
                      value: a.distanceM == null ? '—' : Fmt.km(a.distanceM!),
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      label: 'Moving time',
                      value: a.movingTimeS == null
                          ? '—'
                          : Fmt.duration(a.movingTimeS!),
                      sub: a.elapsedTimeS == null
                          ? null
                          : 'elapsed ${Fmt.duration(a.elapsedTimeS!)}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: 'Avg pace',
                      value: a.paceSPerKm == null
                          ? '—'
                          : Fmt.pace(a.paceSPerKm!),
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      label: 'Heart rate',
                      value: a.avgHr == null ? '—' : '${a.avgHr!.round()} bpm',
                      sub: a.maxHr == null ? null : 'max ${a.maxHr!.round()}',
                    ),
                  ),
                  Expanded(
                    child: StatTile(
                      label: 'Elevation',
                      value: a.elevationGainM == null
                          ? '—'
                          : '${a.elevationGainM!.round()} m',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (a.isStrava && a.externalId != null)
          ViewOnStravaLink(stravaId: a.externalId!),
        if (detailError != null)
          NoticeBanner(
            message: 'Splits unavailable: $detailError',
            color: AppColors.warning,
          ),
        if (a.splits.isNotEmpty) ...[
          const SectionHeader('Splits', subtitle: 'Pace per km'),
          if (full.length >= 2)
            AppCard(
              child: SimpleBarChart(
                values: [for (final s in full) s.paceSPerKm! / 60],
                labels: [for (var i = 0; i < full.length; i++) '${i + 1}'],
                color: AppColors.running,
                highlightLast: false,
                semanticLabel: 'Pace per kilometre split chart',
                valueLabel: (v) => Fmt.pace(v * 60),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppCard(child: _SplitsTable(splits: a.splits)),
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
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SplitsTable extends StatelessWidget {
  const _SplitsTable({required this.splits});
  final List<RunSplit> splits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final muted = t.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Table(
      columnWidths: const {0: FixedColumnWidth(36)},
      children: [
        TableRow(
          children: [
            for (final h in ['Km', 'Dist', 'Time', 'Pace', 'HR', 'Elev'])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(h, style: muted),
              ),
          ],
        ),
        for (var i = 0; i < splits.length; i++)
          TableRow(
            children: [
              Text('${i + 1}', style: t.bodySmall),
              Text(
                (splits[i].distanceM / 1000).toStringAsFixed(2),
                style: t.bodySmall,
              ),
              Text(Fmt.duration(splits[i].movingTimeS), style: t.bodySmall),
              Text(
                splits[i].paceSPerKm == null
                    ? '—'
                    : Fmt.pace(splits[i].paceSPerKm!).replaceAll(' /km', ''),
                style: t.bodySmall,
              ),
              Text(
                splits[i].avgHr?.round().toString() ?? '—',
                style: t.bodySmall,
              ),
              Text(
                splits[i].elevDiffM == null
                    ? '—'
                    : '${splits[i].elevDiffM!.round()} m',
                style: t.bodySmall,
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
          padding: EdgeInsets.all(AppSpacing.lg),
          child: LinearProgressIndicator(),
        ),
        error: (e, _) => _fromSplits(context),
        data: (s) {
          final dist = s['distance'];
          final hr = s['heartrate'];
          final alt = s['altitude'];
          if (dist == null || (hr == null && alt == null)) {
            return _fromSplits(context);
          }
          List<(double, double)> series(List<double> ys) {
            final n = ys.length < dist.length ? ys.length : dist.length;
            final step = (n / 200).ceil().clamp(1, 1 << 20);
            return [
              for (var i = 0; i < n; i += step)
                if (ys[i].isFinite && dist[i].isFinite) (dist[i] / 1000, ys[i]),
            ];
          }

          return Column(
            children: [
              if (hr != null && hr.isNotEmpty) ...[
                const SectionHeader('Heart rate', subtitle: 'bpm vs km'),
                AppCard(
                  child: TrendLineChart(
                    points: series(hr),
                    color: AppColors.heart,
                    curved: false,
                    showDots: false,
                    semanticLabel: 'Heart rate over distance',
                    yLabel: (v) => v.toStringAsFixed(0),
                  ),
                ),
              ],
              if (alt != null && alt.isNotEmpty) ...[
                const SectionHeader('Elevation', subtitle: 'm vs km'),
                AppCard(
                  child: TrendLineChart(
                    points: series(alt),
                    color: AppColors.habit,
                    curved: false,
                    showDots: false,
                    semanticLabel: 'Elevation profile',
                    yLabel: (v) => v.toStringAsFixed(0),
                  ),
                ),
              ],
            ],
          );
        },
      );
    }
    return _fromSplits(context);
  }

  Widget _fromSplits(BuildContext context) {
    final splits = activity.splits;
    final hr = [
      for (var i = 0; i < splits.length; i++)
        if (splits[i].avgHr != null) ((i + 1).toDouble(), splits[i].avgHr!),
    ];
    var cum = 0.0;
    final elev = <(double, double)>[(0, 0)];
    for (var i = 0; i < splits.length; i++) {
      if (splits[i].elevDiffM == null) continue;
      cum += splits[i].elevDiffM!;
      elev.add(((i + 1).toDouble(), cum));
    }
    return Column(
      children: [
        if (hr.length >= 2) ...[
          const SectionHeader('Heart rate', subtitle: 'Average per split'),
          AppCard(
            child: TrendLineChart(
              points: hr,
              color: AppColors.heart,
              semanticLabel: 'Average heart rate per split',
              yLabel: (v) => v.toStringAsFixed(0),
            ),
          ),
        ],
        if (elev.length >= 3) ...[
          const SectionHeader(
            'Elevation',
            subtitle: 'Cumulative change per split (m)',
          ),
          AppCard(
            child: TrendLineChart(
              points: elev,
              color: AppColors.habit,
              semanticLabel: 'Cumulative elevation change per split',
              yLabel: (v) => v.toStringAsFixed(0),
            ),
          ),
        ],
      ],
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});
  final RunReview review;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
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
              const Icon(Icons.rule, size: 16, color: AppColors.info),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  kReviewLabel,
                  style: t.labelMedium?.copyWith(color: AppColors.info),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
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
          const Divider(height: AppSpacing.xl),
          Text('Suggested next workout', style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${review.next.type.label}: ${review.next.description}',
            style: t.bodyMedium,
          ),
          Text(
            review.next.rationale,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Takeaway', style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(review.takeaway, style: t.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          Text(
            review.uncertainty,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
    if (a.isStrava) {
      // Strava API Policy §5.3: no Strava data (or derivatives) may be used
      // with AI, so the button is disabled with an explanation.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OutlinedButton(
            onPressed: null,
            child: Text('Ask AI coach for a deeper review'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Unavailable for Strava activities: Strava\'s API terms prohibit '
            'sharing Strava data with AI. The review above is computed on '
            'this device without AI.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (a.alsoInHealthConnect && a.duplicateIds.isNotEmpty)
            TextButton(
              onPressed: () =>
                  context.push('/running/activity/${a.duplicateIds.first}'),
              child: const Text('Open the Health Connect copy of this run'),
            ),
        ],
      );
    }
    final date = Fmt.weekdayDayMonth(a.startAt);
    return FilledButton.icon(
      icon: const Icon(Icons.auto_awesome),
      label: const Text('Ask AI coach for a deeper review'),
      onPressed: () => context.push(
        '/coach?prompt=${Uri.encodeComponent('Review my run on $date (activity ${a.id})')}',
      ),
    );
  }
}
