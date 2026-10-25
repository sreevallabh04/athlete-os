import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/util/redact.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/providers.dart';
import '../../data/mappers.dart';
import '../../domain/food_models.dart';
import 'amount_sheet.dart';
import 'common.dart';

Future<void> showEditEntrySheet(BuildContext context, FoodLogEntry entry) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
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
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final s = _servings;
    final preview = s == null || e.servings <= 0
        ? null
        : e.nutrients.scale(s / e.servings);
    final estimate = Verifications.isEstimate(e.verification);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e.name, style: t.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SourceBadge(
                  origin: originForSource(e.source),
                  isEstimate: estimate,
                ),
                VerificationLabel(e.verification),
              ],
            ),
            if (e.note != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(e.note!, style: t.bodySmall),
            ],
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: _byGrams ? 'Amount (g)' : 'Servings',
                errorText: _value == null ? 'Enter an amount above 0' : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.md,
                horizontal: AppSpacing.sm,
              ),
              child: preview == null
                  ? const Center(child: Text('Enter an amount'))
                  : NutrientPreview(nutrients: preview, estimate: estimate),
            ),
            const SizedBox(height: AppSpacing.lg),
            MealPicker(
              value: _meal,
              onChanged: (m) => setState(() => _meal = m),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final log = ref.read(foodLogRepositoryProvider);
                      await log.softDelete(e.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: s == null ? null : _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
