import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/report_builder.dart';
import 'charts.dart';
import 'ui_helpers.dart';

/// Renders a [PeriodReport] (freshly generated or loaded from history).
class ReportView extends StatefulWidget {
  const ReportView({super.key, required this.report});
  final PeriodReport report;

  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  String? _seriesKey;

  static Color _color(String key) => switch (key) {
    'kcal' => AppColors.calories,
    'protein' => AppColors.protein,
    'weight' => AppColors.cyan,
    'steps' => AppColors.steps,
    'run_km' => AppColors.running,
    _ => AppColors.brand,
  };

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final t = Theme.of(context).textTheme;
    final series = r.series.where((s) => s.points.isNotEmpty).toList();
    final selected = series.isEmpty
        ? null
        : series.firstWhere(
            (s) => s.key == _seriesKey,
            orElse: () => series.first,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${r.kind == 'monthly' ? 'Monthly' : 'Weekly'} report · '
          '${formatDateKey(r.periodStart, pattern: 'd MMM')} – '
          '${formatDateKey(r.periodEnd, pattern: 'd MMM yyyy')}',
          style: t.titleMedium,
        ),
        Hint(
          '${r.daysCounted} day${r.daysCounted == 1 ? '' : 's'} counted'
          '${r.competitionLine != null ? ' · ${r.competitionLine}' : ''}',
        ),
        const SizedBox(height: AppSpacing.md),
        LayoutBuilder(
          builder: (context, c) {
            final cards = [
              _InsightCard(
                label: 'Most important improvement',
                insight: r.improvement,
                color: AppColors.success,
                icon: Icons.trending_up,
              ),
              _InsightCard(
                label: 'Suggested focus for next week',
                insight: r.focus,
                color: AppColors.brand,
                icon: Icons.center_focus_strong,
              ),
            ];
            if (c.maxWidth < 640) return Column(children: spaced(cards));
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: cards[1]),
              ],
            );
          },
        ),
        if (selected != null) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final s in series) ...[
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 36),
                          child: HudChip(
                            label: s.title,
                            color: s.key == selected.key ? _color(s.key) : null,
                            selected: s.key == selected.key,
                            onTap: () => setState(() => _seriesKey = s.key),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (selected.bar)
                  LabeledBarChart(
                    labels: [
                      for (final p in selected.points)
                        formatDateKey(p.date, pattern: 'd/M'),
                    ],
                    values: [for (final p in selected.points) p.value],
                    color: _color(selected.key),
                    unit: selected.unit,
                    height: 190,
                  )
                else
                  DateLineChart(
                    unit: selected.unit,
                    height: 190,
                    lines: [
                      DateLine(
                        points: selected.points,
                        color: _color(selected.key),
                        label: selected.title,
                      ),
                    ],
                  ),
                const SizedBox(height: AppSpacing.xs),
                Hint(
                  '${selected.title} · ${selected.unit} · source: '
                  '${selected.source}. Days without data are omitted, not '
                  'shown as zero.',
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        LayoutBuilder(
          builder: (context, c) {
            final perRow = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 600 ? 2 : 1);
            final w = (c.maxWidth - AppSpacing.md * (perRow - 1)) / perRow;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                for (final s in r.sections)
                  SizedBox(
                    width: w,
                    child: _SectionCard(section: s),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.label,
    required this.insight,
    required this.color,
    required this.icon,
  });
  final String label;
  final RuleInsight insight;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      accent: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardTitle(
            icon: icon,
            title: label,
            color: color,
            trailing: HudChip(
              label: 'Rule-based',
              uppercase: false,
              color: color,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(insight.title, style: t.titleMedium),
          const SizedBox(height: 2),
          Text(insight.detail, style: t.bodyMedium),
          const SizedBox(height: AppSpacing.xs),
          // Rule numbers are for the code and docs; people get the reason.
          Hint(
            'Why: '
            '${insight.rule.replaceFirst(RegExp(r'^(Rule \d+|Rule-based): '), '')}',
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});
  final ReportSection section;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(section.title.toUpperCase(), style: hud.label(size: 11.5)),
          const SizedBox(height: AppSpacing.md),
          if (!section.available)
            Row(
              children: [
                Icon(Icons.remove, size: 16, color: hud.textMuted),
                const SizedBox(width: 6),
                Expanded(child: Hint(section.note ?? 'No data')),
              ],
            ),
          LayoutBuilder(
            builder: (context, box) {
              final w = (box.maxWidth - AppSpacing.md) / 2;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (final m in section.metrics)
                    SizedBox(
                      width: w,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.label,
                            style: t.labelMedium?.copyWith(
                              color: hud.textMuted,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            m.value,
                            style: t.titleMedium?.copyWith(
                              fontFamily: AppFonts.display,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (m.detail != null || m.source != null)
                            Text(
                              [
                                ?m.detail,
                                if (m.source != null) m.source!,
                              ].join(' · '),
                              style: t.labelSmall?.copyWith(
                                color: hud.textMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          if (section.available && section.note != null) ...[
            const SizedBox(height: AppSpacing.md),
            Hint(section.note!),
          ],
        ],
      ),
    );
  }
}
