import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../application/providers.dart';
import '../domain/nutrition_calc.dart';
import 'widgets/common.dart';

class HydrationScreen extends ConsumerWidget {
  const HydrationScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref, int ml) async {
    try {
      final id = await ref.read(waterRepositoryProvider).add(ml);
      await HapticFeedback.lightImpact();
      if (!context.mounted) return;
      showSnack(
        context,
        'Added ${Fmt.ml(ml)}',
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => ref.read(waterRepositoryProvider).remove(id),
        ),
      );
    } catch (e) {
      if (context.mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  Future<void> _custom(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final ml = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add water'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            suffixText: 'ml',
            helperText: '1–5000 ml',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text.trim());
              if (v != null && v > 0 && v <= 5000) Navigator.pop(ctx, v);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (ml != null && context.mounted) await _add(context, ref, ml);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final logs = ref.watch(waterDayProvider(today));
    final week = ref.watch(waterWeekProvider(today));
    final profile = ref.watch(profileProvider);
    final goal = profile.value?.waterGoalMl ?? 0;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(clockProvider).now();

    return AppPage(
      title: 'Hydration',
      children: [
        ...logs.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (list) {
            final h = HydrationSummary.fromAmounts(
              list.map((w) => w.amountMl),
              goal,
            );
            final label = !h.hasGoal
                ? 'No goal set'
                : h.remainingMl > 0
                ? '${Fmt.ml(h.remainingMl)} to go'
                : h.remainingMl == 0
                ? 'Goal reached'
                : 'Goal reached · +${Fmt.ml(-h.remainingMl)}';
            return [
              AppCard(
                accent: AppColors.water,
                child: Column(
                  children: [
                    ProgressRing(
                      progress: h.visualProgress,
                      color: AppColors.water,
                      size: 180,
                      stroke: 16,
                      semanticLabel: 'Water today',
                      center: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            Fmt.ml(h.totalMl),
                            style: t.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'of ${Fmt.ml(goal)}',
                            style: t.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(label, style: t.titleSmall),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        for (final ml in const [150, 250, 500]) ...[
                          Expanded(
                            child: SizedBox(
                              height: 52,
                              child: FilledButton.tonal(
                                onPressed: () => _add(context, ref, ml),
                                child: Text('+${Fmt.ml(ml)}'),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            onPressed: () => _custom(context, ref),
                            child: const Text('Custom'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SectionHeader('Today'),
              if (list.isEmpty)
                const EmptyState(
                  compact: true,
                  icon: Icons.water_drop_outlined,
                  title: 'No water logged today',
                )
              else
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _WaterTile(log: list[i], now: now),
                      ],
                    ],
                  ),
                ),
            ];
          },
        ),
        const SectionHeader('Last 7 days'),
        AppCard(
          child: week.when(
            loading: () => const SizedBox(height: 180, child: LoadingState()),
            error: (e, _) => ErrorState(message: redactSecrets('$e')),
            data: (byDay) => _WeekChart(byDay: byDay, goal: goal),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        NoticeBanner(
          message:
              'Fluid needs vary with activity, climate, body size and '
              'health. Your goal (${Fmt.ml(goal)}) is set by you, not '
              'prescribed by the app.',
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            TextButton.icon(
              onPressed: () => context.push(AppPaths.profile),
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: const Text('Edit goal'),
            ),
            TextButton.icon(
              onPressed: () => context.push(AppPaths.notificationSettings),
              icon: const Icon(Icons.notifications_outlined, size: 18),
              label: const Text('Reminder settings'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WaterTile extends ConsumerWidget {
  const _WaterTile({required this.log, required this.now});
  final WaterLog log;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey('water-${log.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.xl),
        color: AppColors.danger.withValues(alpha: 0.85),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        await _delete(context, ref);
        return false;
      },
      child: ListTile(
        leading: const Icon(Icons.water_drop, color: AppColors.water),
        title: Text(Fmt.ml(log.amountMl)),
        subtitle: Text(
          '${Fmt.time(log.loggedAt)} · '
          '${log.source == 'manual' ? 'Manual' : log.source}',
        ),
        trailing: IconButton(
          tooltip: 'Delete ${Fmt.ml(log.amountMl)}',
          icon: const Icon(Icons.close),
          onPressed: () => _delete(context, ref),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(waterRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await repo.remove(log.id);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed ${Fmt.ml(log.amountMl)}'),
          action: SnackBarAction(
            label: 'Undo',
            // WaterRepository has no restore; re-add the same amount at the
            // original time and source.
            onPressed: () =>
                repo.add(log.amountMl, at: log.loggedAt, source: log.source),
          ),
        ),
      );
  }
}

class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.byDay, required this.goal});
  final Map<String, int> byDay;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = byDay.keys.toList()..sort();
    final maxVal = [
      ...byDay.values,
      goal,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = maxVal <= 0 ? 1000.0 : maxVal * 1.15;
    final logged = byDay.values.where((v) => v > 0).toList();
    final avg = logged.isEmpty
        ? 0
        : logged.reduce((a, b) => a + b) / logged.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          logged.isEmpty
              ? 'No water logged in the last 7 days'
              : 'Average ${Fmt.ml(avg)} on ${logged.length} logged '
                    'day${logged.length == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          height: 180,
          child: Semantics(
            label:
                'Water per day: '
                '${keys.map((k) => '${DateFormat.E().format(LocalDates.parse(k))} ${Fmt.ml(byDay[k]!)}').join(', ')}',
            excludeSemantics: true,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                minY: 0,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barTouchData: const BarTouchData(enabled: false),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (goal > 0)
                      HorizontalLine(
                        y: goal.toDouble(),
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        strokeWidth: 1,
                        dashArray: [4, 4],
                      ),
                  ],
                ),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (i < 0 || i >= keys.length) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          meta: meta,
                          child: Text(
                            DateFormat.E().format(LocalDates.parse(keys[i])),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < keys.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: byDay[keys[i]]!.toDouble(),
                          width: 18,
                          color: goal > 0 && byDay[keys[i]]! >= goal
                              ? AppColors.water
                              : AppColors.water.withValues(alpha: 0.55),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(6),
                          ),
                        ),
                      ],
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
