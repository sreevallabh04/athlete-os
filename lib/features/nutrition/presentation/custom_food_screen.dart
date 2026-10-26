import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';

/// Create (or edit) a food by hand. Can be prefilled from an incomplete Open
/// Food Facts product or with a scanned barcode. Pops with the saved [Food].
class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({
    super.key,
    this.prefill,
    this.barcode,
    this.edit,
    this.initialName,
  });

  final FoodCandidate? prefill;
  final String? barcode;
  final Food? edit;

  /// Name to start with (e.g. the search query that found nothing).
  final String? initialName;

  @override
  ConsumerState<CustomFoodScreen> createState() => _CustomFoodScreenState();
}

class _CustomFoodScreenState extends ConsumerState<CustomFoodScreen> {
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _barcode = TextEditingController();
  final _size = TextEditingController(text: '100');
  final _grams = TextEditingController();
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _fiber = TextEditingController();
  String _unit = 'g';
  bool _favorite = false;
  Map<String, String> _errors = const {};
  bool _saving = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    String n(double? v) => v == null ? '' : plainNum(v);
    final e = widget.edit;
    final p = widget.prefill;
    if (e != null) {
      _name.text = e.name;
      _brand.text = e.brand ?? '';
      _barcode.text = e.barcode ?? '';
      _size.text = n(e.servingSize);
      _unit = servingUnits.contains(e.servingUnit) ? e.servingUnit : 'serving';
      _grams.text = n(e.gramsPerServing);
      _kcal.text = n(e.calories);
      _protein.text = n(e.proteinG);
      _carbs.text = n(e.carbsG);
      _fat.text = n(e.fatG);
      _fiber.text = n(e.fiberG);
      _favorite = e.isFavorite;
    } else if (p != null) {
      _name.text = p.name;
      _brand.text = p.brand ?? '';
      _barcode.text = p.barcode ?? '';
      // Prefer whichever basis has more known values.
      final per100Known = [
        p.kcal100g,
        p.protein100g,
        p.carbs100g,
        p.fat100g,
      ].whereType<double>().length;
      final servKnown = [
        p.kcalServing,
        p.proteinServing,
        p.carbsServing,
        p.fatServing,
      ].whereType<double>().length;
      if (servKnown > per100Known && p.servingQuantity != null) {
        _size.text = n(p.servingQuantity);
        _unit = p.servingUnit;
        _kcal.text = n(p.kcalServing);
        _protein.text = n(p.proteinServing);
        _carbs.text = n(p.carbsServing);
        _fat.text = n(p.fatServing);
        _fiber.text = n(p.fiberServing);
      } else {
        _size.text = '100';
        _unit = p.servingUnit;
        _kcal.text = n(p.kcal100g);
        _protein.text = n(p.protein100g);
        _carbs.text = n(p.carbs100g);
        _fat.text = n(p.fat100g);
        _fiber.text = n(p.fiber100g);
      }
    } else {
      _name.text = widget.initialName?.trim() ?? '';
      _barcode.text = widget.barcode ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _brand,
      _barcode,
      _size,
      _grams,
      _kcal,
      _protein,
      _carbs,
      _fat,
      _fiber,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _validate() => validateFoodInput(
    name: _name.text,
    servingSize: _size.text,
    servingUnit: _unit,
    gramsPerServing: _grams.text,
    calories: _kcal.text,
    protein: _protein.text,
    carbs: _carbs.text,
    fat: _fat.text,
    fiber: _fiber.text,
    barcode: _barcode.text,
  );

  double? _d(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _save() async {
    setState(() {
      _submitted = true;
      _errors = _validate();
    });
    if (_errors.isNotEmpty) {
      Haptics.warning();
      return;
    }
    final weightUnit = _unit == 'g' || _unit == 'ml';
    final size = _d(_size)!;
    final basis = ServingBasis(
      perServing: Nutrients(
        calories: _d(_kcal)!,
        protein: _d(_protein)!,
        carbs: _d(_carbs)!,
        fat: _d(_fat)!,
        fiber: _d(_fiber),
      ),
      servingSize: size,
      servingUnit: _unit,
      gramsPerServing: weightUnit ? size : _d(_grams),
    );
    final p = widget.prefill;
    final draft = FoodDraft(
      name: _name.text,
      brand: _brand.text,
      barcode: _barcode.text,
      basis: basis,
      source: widget.edit?.source ?? p?.source ?? FoodSources.custom,
      sourceId: widget.edit?.sourceId ?? p?.sourceId,
      // Anything typed in by hand is user_entered, even if it started from
      // a partial database record.
      verification: Verifications.userEntered,
      rawJson: p == null
          ? null
          : jsonEncode({...p.raw, 'completed_by_user': true}),
      isFavorite: _favorite,
    );
    setState(() => _saving = true);
    try {
      final repo = ref.read(foodRepositoryProvider);
      Food food;
      if (widget.edit != null) {
        await repo.update(widget.edit!.id, draft);
        await repo.setFavorite(widget.edit!.id, _favorite);
        food = (await repo.get(widget.edit!.id))!;
      } else {
        food = await repo.create(draft);
      }
      Haptics.success();
      if (mounted) Navigator.of(context).pop(food);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Could not save: ${redactSecrets(e.toString())}');
      }
    }
  }

  Widget _num(
    String key,
    TextEditingController c,
    String label, {
    String? suffix,
    String? helper,
  }) {
    return TextField(
      key: Key('food-$key'),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        helperText: helper,
        errorText: _errors[key],
      ),
      onChanged: (_) {
        if (_submitted) _errors = _validate();
        setState(() {});
      },
    );
  }

  Nutrients? get _preview {
    final k = _d(_kcal);
    if (k == null) return null;
    return Nutrients(
      calories: k,
      protein: _d(_protein) ?? 0,
      carbs: _d(_carbs) ?? 0,
      fat: _d(_fat) ?? 0,
      fiber: _d(_fiber),
    );
  }

  @override
  Widget build(BuildContext context) {
    final weightUnit = _unit == 'g' || _unit == 'ml';
    final p = widget.prefill;
    final hud = context.hud;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.edit != null ? 'Edit food' : 'Create food'),
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          MediaQuery.paddingOf(context).bottom + AppSpacing.xxxl,
        ),
        children: [
          if (p != null) ...[
            NoticeBanner(
              icon: Icons.fact_check_outlined,
              color: AppColors.warning,
              message:
                  'Partially filled from ${FoodSources.label(p.source)}. '
                  'Missing: ${p.missingNutrients.join(', ')}. Copy the '
                  'values from the package label.',
            ),
            if (p.source == FoodSources.openFoodFacts) ...[
              const SizedBox(height: AppSpacing.xs),
              const OffAttribution(),
            ],
            const SizedBox(height: AppSpacing.lg),
          ],
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HudCaption('Food'),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  key: const Key('food-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Name *',
                    errorText: _errors['name'],
                  ),
                  onChanged: (_) {
                    if (_submitted) setState(() => _errors = _validate());
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _brand,
                  decoration: const InputDecoration(
                    labelText: 'Brand (optional)',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _barcode,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Barcode (optional)',
                    prefixIcon: const Icon(Icons.qr_code_2_rounded),
                    errorText: _errors['barcode'],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HudCaption('Serving'),
                const SizedBox(height: 2),
                Text(
                  'Nutrition values below are for one serving.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: hud.textMuted),
                ),
                const SizedBox(height: AppSpacing.md),
                _num('servingSize', _size, 'Serving size *', suffix: _unit),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final u in servingUnits)
                      HudChip(
                        label: u,
                        // Units are case-sensitive ("g", "ml"): never shout them.
                        uppercase: false,
                        selected: u == _unit,
                        onTap: () => setState(() => _unit = u),
                      ),
                  ],
                ),
                if (!weightUnit) ...[
                  const SizedBox(height: AppSpacing.md),
                  _num(
                    'gramsPerServing',
                    _grams,
                    'Grams per serving (optional)',
                    suffix: 'g',
                    helper: 'Lets you log this food by weight too',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            accent: AppColors.calories,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HudCaption(
                  'Nutrition per serving',
                  color: AppColors.calories,
                ),
                const SizedBox(height: AppSpacing.md),
                _num('calories', _kcal, 'Calories *', suffix: 'kcal'),
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _num(
                        'protein',
                        _protein,
                        'Protein *',
                        suffix: 'g',
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: _num('carbs', _carbs, 'Carbs *', suffix: 'g'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _num('fat', _fat, 'Fat *', suffix: 'g')),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: _num(
                        'fiber',
                        _fiber,
                        'Fiber (optional)',
                        suffix: 'g',
                      ),
                    ),
                  ],
                ),
                if (preview != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  NutrientPreview(nutrients: preview),
                  const SizedBox(height: AppSpacing.md),
                  MacroSplitBar(
                    protein: preview.protein,
                    carbs: preview.carbs,
                    fat: preview.fat,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Row(
              children: [
                Icon(
                  _favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: _favorite ? AppColors.gold : hud.textMuted,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'Add to favorites',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                HudToggle(
                  value: _favorite,
                  semanticLabel: 'Add to favorites',
                  onChanged: (v) => setState(() => _favorite = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          KeyedSubtree(
            key: const Key('food-save'),
            child: HudButton(
              label: widget.edit != null ? 'Save changes' : 'Save food',
              icon: Icons.check_rounded,
              expand: true,
              loading: _saving,
              onPressed: _saving ? null : _save,
            ),
          ),
        ],
      ),
    );
  }
}
