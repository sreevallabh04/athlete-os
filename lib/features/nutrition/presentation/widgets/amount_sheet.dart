import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/domain/provenance.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/food_models.dart';
import '../../domain/nutrients.dart';
import 'common.dart';

class AmountSheetResult {
  const AmountSheetResult(this.amount, this.meal);
  final Amount amount;
  final MealType? meal;
}

/// Bottom sheet to choose an amount (servings or grams) with a live macro
/// preview, and optionally the meal. Returns null when dismissed.
Future<AmountSheetResult?> showAmountSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required ServingBasis basis,
  required String verification,
  required DataOrigin origin,
  MealType? initialMeal,
  String actionLabel = 'Log',
  bool showOffAttribution = false,
  Amount? initialAmount,
  Widget? extra,
}) {
  return showModalBottomSheet<AmountSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => AmountSheet(
      title: title,
      subtitle: subtitle,
      basis: basis,
      verification: verification,
      origin: origin,
      initialMeal: initialMeal,
      actionLabel: actionLabel,
      showOffAttribution: showOffAttribution,
      initialAmount: initialAmount,
      extra: extra,
    ),
  );
}

class AmountSheet extends StatefulWidget {
  const AmountSheet({
    super.key,
    required this.title,
    this.subtitle,
    required this.basis,
    required this.verification,
    required this.origin,
    this.initialMeal,
    this.actionLabel = 'Log',
    this.showOffAttribution = false,
    this.initialAmount,
    this.extra,
  });

  final String title;
  final String? subtitle;
  final ServingBasis basis;
  final String verification;
  final DataOrigin origin;
  final MealType? initialMeal;
  final String actionLabel;
  final bool showOffAttribution;
  final Amount? initialAmount;
  final Widget? extra;

  @override
  State<AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<AmountSheet> {
  late AmountMode _mode;
  late final TextEditingController _ctrl;
  MealType? _meal;

  @override
  void initState() {
    super.initState();
    final init = widget.initialAmount;
    _mode = init?.mode ?? AmountMode.servings;
    if (_mode == AmountMode.grams && !widget.basis.supportsGrams) {
      _mode = AmountMode.servings;
    }
    _ctrl = TextEditingController(
      text: init != null ? plainNum(init.value) : '1',
    );
    _meal = widget.initialMeal;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (v == null || !v.isFinite || v <= 0 || v > 100000) return null;
    return v;
  }

  Amount? get _amount {
    final v = _value;
    if (v == null) return null;
    return _mode == AmountMode.grams ? Amount.grams(v) : Amount.servings(v);
  }

  void _switchMode(AmountMode m) {
    final current = _value;
    final gps = widget.basis.gramsPerServing;
    setState(() {
      if (current != null && gps != null && gps > 0) {
        final converted = m == AmountMode.grams ? current * gps : current / gps;
        _ctrl.text = plainNum(converted);
      } else {
        _ctrl.text = m == AmountMode.grams ? plainNum(gps ?? 100) : '1';
      }
      _mode = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final amount = _amount;
    final preview = amount == null
        ? null
        : resolveAmount(widget.basis, amount).nutrients;
    final unit = widget.basis.baseUnit;
    final estimate = Verifications.isEstimate(widget.verification);
    final chips = _mode == AmountMode.grams
        ? const [50.0, 100.0, 150.0, 200.0, 250.0]
        : const [0.5, 1.0, 1.5, 2.0, 3.0];

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
            Text(widget.title, style: t.titleLarge),
            if (widget.subtitle != null)
              Text(
                widget.subtitle!,
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SourceBadge(origin: widget.origin, isEstimate: estimate),
                VerificationLabel(widget.verification),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '1 serving = ${widget.basis.servingLabel} · '
              '${Fmt.kcal(widget.basis.perServing.calories)}',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (widget.showOffAttribution) ...[
              const SizedBox(height: AppSpacing.xs),
              const OffAttribution(),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (widget.basis.supportsGrams)
              SegmentedButton<AmountMode>(
                segments: [
                  const ButtonSegment(
                    value: AmountMode.servings,
                    label: Text('Servings'),
                  ),
                  ButtonSegment(
                    value: AmountMode.grams,
                    label: Text(unit == 'ml' ? 'Millilitres' : 'Grams'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => _switchMode(s.first),
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('amount-field'),
              controller: _ctrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: _mode == AmountMode.grams
                    ? 'Amount ($unit)'
                    : 'Servings',
                errorText: amount == null ? 'Enter an amount above 0' : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final c in chips)
                  ActionChip(
                    label: Text(
                      _mode == AmountMode.grams
                          ? '${Fmt.oneDp(c)} $unit'
                          : '${Fmt.oneDp(c)}×',
                    ),
                    onPressed: () => setState(() => _ctrl.text = plainNum(c)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.md,
                horizontal: AppSpacing.sm,
              ),
              child: preview == null
                  ? const Center(child: Text('Enter an amount to preview'))
                  : NutrientPreview(nutrients: preview, estimate: estimate),
            ),
            if (_meal != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Meal', style: t.labelLarge),
              const SizedBox(height: AppSpacing.xs),
              MealPicker(
                value: _meal!,
                onChanged: (m) => setState(() => _meal = m),
              ),
            ],
            if (widget.extra != null) ...[
              const SizedBox(height: AppSpacing.md),
              widget.extra!,
            ],
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: amount == null
                    ? null
                    : () =>
                          Navigator.of(context)
                              .pop(AmountSheetResult(amount, _meal)),
                child: Text(widget.actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Meal type chooser.
class MealPicker extends StatelessWidget {
  const MealPicker({super.key, required this.value, required this.onChanged});
  final MealType value;
  final ValueChanged<MealType> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final m in MealType.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: ChoiceChip(
                label: Text(m.label),
                selected: m == value,
                onSelected: (_) => onChanged(m),
              ),
            ),
        ],
      ),
    );
  }
}
