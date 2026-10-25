import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/util/redact.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/providers.dart';
import '../../data/mappers.dart';
import '../../domain/food_models.dart';
import 'amount_sheet.dart';
import 'common.dart';
import 'nutrition_hud.dart';

Future<void> showEditEntrySheet(BuildContext context, FoodLogEntry entry) =>
    showHudBottomSheet<void>(
      context,
      builder: (_) => EditEntrySheet(entry: entry),
    );

/// Edit amount / meal of a logged entry. The nutrient snapshot is rescaled
/// proportionally; the food definition is not consulted.
class EditEntrySheet extends ConsumerStatefulWidget {
  const EditEntrySheet({super.key, required this.entry});
  final FoodLogEntry entry;

  @override
  ConsumerState<EditEntrySheet> createState() => _EditEntrySheetState();
}

class _EditEntrySheetState extends ConsumerState<EditEntrySheet> {
  late final TextEditingController _amount;
  late MealType _meal;
  late final bool _byGrams;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _byGrams = e.grams != null && e.grams! > 0;
    _amount = TextEditingController(
      text: plainNum(_byGrams ? e.grams! : e.servings),
    );
    _meal = MealType.fromKey(e.mealType);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    return v != null && v.isFinite && v > 0 ? v : null;
  }

  /// New servings implied by the typed value.
  double? get _servings {
    final v = _value;
    if (v == null) return null;
    final e = widget.entry;
    if (_byGrams) return v / (e.grams! / e.servings);
    return v;
  }

  Future<void> _save() async {
    final s = _servings;
    if (s == null) return;
    try {
      await ref
          .read(foodLogRepositoryProvider)
          .updateEntry(widget.entry.id, servings: s, mealType: _meal);
      Haptics.success();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  Future<void> _delete() async {
    final e = widget.entry;
    final log = ref.read(foodLogRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Haptics.heavy();
    await log.softDelete(e.id);
    if (mounted) Navigator.of(context).pop();
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted ${e.name}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => log.restore(e.id),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final s = _servings;
    final preview = s == null || e.servings <= 0
        ? null
        : e.nutrients.scale(s / e.servings);
    final estimate = Verifications.isEstimate(e.verification);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(e.name, style: t.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SourceBadge(
                origin: originForSource(e.source),
                isEstimate: estimate,
              ),
              VerificationLabel(e.verification),
              Text(
                'LOGGED ${Fmt.time(e.loggedAt).toUpperCase()}',
                style: hud.mono(size: 10.5),
              ),
            ],
          ),
          if (e.note != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(e.note!, style: t.bodySmall),
          ],
          const SizedBox(height: AppSpacing.lg),
          AmountStepper(
            controller: _amount,
            unitLabel: _byGrams ? 'g' : (_value == 1 ? 'serving' : 'servings'),
            step: _byGrams ? 5 : 0.25,
            max: _byGrams ? 3000 : 30,
            valid: _value != null,
            onChanged: (v) => setState(() => _amount.text = plainNum(v)),
            onTyped: () => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.lg),
          GlassPanel(
            accent: estimate ? AppColors.warning : null,
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.md,
              horizontal: AppSpacing.sm,
            ),
            child: preview == null
                ? Center(
                    child: Text(
                      'Enter an amount',
                      style: t.bodyMedium?.copyWith(color: hud.textMuted),
                    ),
                  )
                : Column(
                    children: [
                      NutrientPreview(nutrients: preview, estimate: estimate),
                      const SizedBox(height: AppSpacing.md),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        child: MacroSplitBar(
                          protein: preview.protein,
                          carbs: preview.carbs,
                          fat: preview.fat,
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('MEAL', style: hud.label(size: 11)),
          const SizedBox(height: AppSpacing.sm),
          MealPicker(value: _meal, onChanged: (m) => setState(() => _meal = m)),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: AppColors.red),
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: HudButton(
                  label: 'Save',
                  icon: Icons.check_rounded,
                  expand: true,
                  onPressed: s == null ? null : _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
