import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../../nutrition/application/providers.dart';

/// Amounts offered by the quick-add sheet.
const quickAddWaterAmounts = [150, 250, 500, 750];

/// Opens the water quick-add sheet ("Log water" launcher shortcut).
Future<void> showWaterQuickAddSheet(BuildContext context) =>
    showHudBottomSheet<void>(
      context,
      title: 'Log water',
      builder: (_) => const WaterQuickAddSheet(),
    );

/// One-tap water logging: today's total vs goal and four amounts. Each tap
/// logs immediately (source `manual`) and closes the sheet.
class WaterQuickAddSheet extends ConsumerStatefulWidget {
  const WaterQuickAddSheet({super.key});

  @override
  ConsumerState<WaterQuickAddSheet> createState() => _WaterQuickAddSheetState();
}

class _WaterQuickAddSheetState extends ConsumerState<WaterQuickAddSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _log(int ml) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(waterRepositoryProvider);
      final id = await repo.add(ml);
      Haptics.success();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Logged $ml ml water'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repo.remove(id),
          ),
        ),
      );
    } catch (_) {
      Haptics.warning();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't log water. Try again.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final date = LocalDates.key(ref.watch(clockProvider).now());
    final logs = ref.watch(waterDayProvider(date)).value;
    final goal = ref.watch(profileProvider).value?.waterGoalMl;
    final total = logs?.fold<int>(0, (s, w) => s + w.amountMl);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('TODAY', style: hud.label(color: AppColors.water)),
          const SizedBox(height: AppSpacing.xs),
          Text(
            total == null || logs!.isEmpty
                ? 'Nothing logged yet${goal == null ? '' : ' · goal ${_litres(goal)}'}'
                : '${_litres(total)}${goal == null ? '' : ' of ${_litres(goal)}'}',
            style: t.titleMedium,
          ),
          if (total != null && goal != null && goal > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            MetricBar(
              label: 'Water',
              value: total.toDouble(),
              target: goal.toDouble(),
              color: AppColors.water,
              unit: 'ml',
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              for (final (i, ml) in quickAddWaterAmounts.indexed) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ml == 250
                      ? HudButton(
                          label: '+$ml',
                          onPressed: _busy ? null : () => _log(ml),
                        )
                      : HudButton.secondary(
                          label: '+$ml',
                          onPressed: _busy ? null : () => _log(ml),
                        ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('AMOUNTS IN ML · LOGS INSTANTLY', style: hud.mono(size: 10.5)),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: t.bodySmall?.copyWith(color: AppColors.red)),
          ],
        ],
      ),
    );
  }
}

String _litres(int ml) => ml >= 1000
    ? '${(ml / 1000).toStringAsFixed(ml % 1000 == 0 ? 0 : 2)} L'
    : '$ml ml';
