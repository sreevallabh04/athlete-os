import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/planning_providers.dart';
import '../data/data_export.dart';
import '../data/metrics_queries.dart';
import '../data/planning_repository.dart';
import '../domain/report_builder.dart';
import 'widgets/report_view.dart';
import 'widgets/ui_helpers.dart';

/// Period helpers for weekly (Monday-start) and calendar-month reports.
(String, String) reportPeriod(String kind, String anchor) {
  if (kind == 'monthly') {
    final d = LocalDates.parse(anchor);
    final start = LocalDates.key(DateTime(d.year, d.month, 1));
    final end = LocalDates.key(DateTime(d.year, d.month + 1, 0));
    return (start, end);
  }
  final start = LocalDates.weekStart(anchor);
  return (start, LocalDates.addDays(start, 6));
}

String shiftPeriod(String kind, String anchor, int by) {
  if (kind == 'monthly') {
    final d = LocalDates.parse(anchor);
    return LocalDates.key(DateTime(d.year, d.month + by, 1));
  }
  return LocalDates.addDays(anchor, 7 * by);
}

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  String _kind = 'weekly';
  late String _anchor = LocalDates.key(ref.read(clockProvider).now());
  PeriodReport? _report;
  bool _loading = false;
  bool _saved = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
      _saved = false;
    });
    try {
      final q = ref.read(metricsQueriesProvider);
      final now = ref.read(clockProvider).now();
      final (start, end) = reportPeriod(_kind, _anchor);
      final (ps, pe) = reportPeriod(_kind, shiftPeriod(_kind, _anchor, -1));
      final input = await q.reportInput(
        kind: _kind,
        start: start,
        end: end,
        now: now,
      );
      final prev = await q.reportInput(
        kind: _kind,
        start: ps,
        end: pe,
        now: now,
      );
      final report = ReportBuilder.build(input, previous: prev);
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not build the report.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final r = _report;
    if (r == null) return;
    await ref
        .read(planningRepositoryProvider)
        .saveReport(
          kind: r.kind,
          periodStart: r.periodStart,
          periodEnd: r.periodEnd,
          content: r.toJson(),
        );
    if (mounted) {
      setState(() => _saved = true);
      showSnack(context, 'Report saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (start, end) = reportPeriod(_kind, _anchor);
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final isFuture = start.compareTo(today) > 0;
    return AppPage(
      title: 'Reports',
      subtitle: 'Generated on demand from your data — nothing is estimated.',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'weekly',
              label: Text('Weekly'),
              icon: Icon(Icons.view_week_outlined),
            ),
            ButtonSegment(
              value: 'monthly',
              label: Text('Monthly'),
              icon: Icon(Icons.calendar_month_outlined),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() {
            _kind = s.first;
            _report = null;
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous period',
              onPressed: () => setState(() {
                _anchor = shiftPeriod(_kind, _anchor, -1);
                _report = null;
              }),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${formatDateKey(start, pattern: 'd MMM')} – '
                '${formatDateKey(end, pattern: 'd MMM yyyy')}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Next period',
              onPressed: isFuture
                  ? null
                  : () => setState(() {
                      _anchor = shiftPeriod(_kind, _anchor, 1);
                      _report = null;
                    }),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _loading || isFuture ? null : _generate,
                icon: const Icon(Icons.auto_graph),
                label: Text(_report == null ? 'Generate report' : 'Regenerate'),
              ),
            ),
            if (_report != null) ...[
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _saved ? null : _save,
                icon: Icon(_saved ? Icons.check : Icons.save_outlined),
                label: Text(_saved ? 'Saved' : 'Save'),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_loading) const LoadingState(),
        if (_error != null) ErrorState(message: _error!, onRetry: _generate),
        if (!_loading && _report != null) ReportView(report: _report!),
        if (!_loading && _report == null && _error == null)
          const AppCard(
            child: EmptyState(
              compact: true,
              icon: Icons.insights_outlined,
              title: 'Pick a period and generate',
              message:
                  'Reports aggregate nutrition, body weight, steps, runs, '
                  'strength, hydration, habits, mood and sleep — only where '
                  'data exists.',
            ),
          ),
        const SectionHeader(
          'Export CSV',
          subtitle: 'Per dataset, for the selected period',
        ),
        _CsvExportCard(start: start, end: end),
        const SectionHeader('Saved reports'),
        const _SavedReports(),
      ],
    );
  }
}

class _CsvExportCard extends ConsumerStatefulWidget {
  const _CsvExportCard({required this.start, required this.end});
  final String start;
  final String end;

  @override
  ConsumerState<_CsvExportCard> createState() => _CsvExportCardState();
}

class _CsvExportCardState extends ConsumerState<_CsvExportCard> {
  final _selected = <ExportDataset>{ExportDataset.foodLog};
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final svc = ref.read(dataExportServiceProvider);
      final files = <XFile>[];
      for (final ds in ExportDataset.values.where(_selected.contains)) {
        final csv = await svc.exportCsv(ds, widget.start, widget.end);
        files.add(
          XFile.fromData(
            utf8.encode(csv),
            mimeType: 'text/csv',
            name: 'athlete_os_${ds.name}_${widget.start}_${widget.end}.csv',
          ),
        );
      }
      await SharePlus.instance.share(
        ShareParams(
          files: files,
          fileNameOverrides: [for (final f in files) f.name],
          subject: 'Athlete OS export ${widget.start} – ${widget.end}',
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, 'Export failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final ds in ExportDataset.values)
                FilterChip(
                  label: Text(ds.label),
                  avatar: ds == ExportDataset.journal
                      ? const Icon(Icons.lock_outline, size: 16)
                      : null,
                  selected: _selected.contains(ds),
                  onSelected: (v) => setState(
                    () => v ? _selected.add(ds) : _selected.remove(ds),
                  ),
                ),
            ],
          ),
          if (_selected.contains(ExportDataset.journal))
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.sm),
              child: NoticeBanner(
                icon: Icons.lock_outline,
                color: AppColors.warning,
                message:
                    'Journal entries are private. They are only included '
                    'because you selected them.',
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          const Hint(
            'Each dataset is its own file with source columns; metrics with '
            'different units are never combined. Imported data remains subject '
            'to the source service’s terms.',
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.tonalIcon(
            onPressed: _busy || _selected.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share),
            label: Text(
              'Export ${_selected.length} file${_selected.length == 1 ? '' : 's'}',
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedReports extends ConsumerWidget {
  const _SavedReports();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(savedReportsProvider);
    return reports.when(
      loading: () => const LoadingState(),
      error: (e, _) =>
          const ErrorState(message: 'Could not load saved reports.'),
      data: (list) {
        final shown = list
            .where(
              (r) =>
                  r.kind == 'weekly' ||
                  r.kind == 'monthly' ||
                  r.kind == 'weekly_review',
            )
            .toList();
        if (shown.isEmpty) {
          return const AppCard(child: Hint('No saved reports yet.'));
        }
        return AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            children: [
              for (final r in shown)
                ListTile(
                  leading: Icon(
                    r.kind == 'weekly_review'
                        ? Icons.rate_review_outlined
                        : Icons.description_outlined,
                  ),
                  title: Text(
                    '${switch (r.kind) {
                      'monthly' => 'Monthly report',
                      'weekly_review' => 'Weekly review',
                      _ => 'Weekly report',
                    }} · ${formatDateKey(r.periodStart, pattern: 'd MMM')} – '
                    '${formatDateKey(r.periodEnd, pattern: 'd MMM yyyy')}',
                  ),
                  subtitle: Text(
                    'Saved ${formatDateKey(LocalDates.key(r.createdAt))}',
                  ),
                  onTap: () => _open(context, r),
                  trailing: IconButton(
                    tooltip: 'Delete report',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirm(
                        context,
                        title: 'Delete saved report?',
                        message: 'This removes the saved snapshot only.',
                        confirmLabel: 'Delete',
                        destructive: true,
                      );
                      if (ok) {
                        await ref
                            .read(planningRepositoryProvider)
                            .deleteReport(r.id);
                      }
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _open(BuildContext context, Report r) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(r.contentJson) as Map<String, dynamic>;
    } catch (_) {
      showSnack(context, 'This saved report could not be read.');
      return;
    }
    Widget body;
    if (r.kind == 'weekly_review') {
      final refl = (json['reflection'] as Map?)?.cast<String, dynamic>() ?? {};
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (k, label) in const [
            ('wins', 'What went well'),
            ('challenges', 'What was hard'),
            ('nextFocus', 'Focus for next week'),
          ]) ...[
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(
              (refl[k] as String?)?.isNotEmpty == true
                  ? refl[k] as String
                  : '—',
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      );
    } else {
      try {
        body = ReportView(report: PeriodReport.fromJson(json));
      } catch (_) {
        showSnack(context, 'This saved report could not be read.');
        return;
      }
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        builder: (context, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.xxl,
          ),
          child: body,
        ),
      ),
    );
  }
}
