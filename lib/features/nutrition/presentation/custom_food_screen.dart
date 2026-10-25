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

/// Create (or edit) a food by hand. Can be prefilled from an incomplete Open
/// Food Facts product or with a scanned barcode. Pops with the saved [Food].
class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({super.key, this.prefill, this.barcode, this.edit});

  final FoodCandidate? prefill;
  final String? barcode;
  final Food? edit;

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
    } else if (widget.barcode != null) {
      _barcode.text = widget.barcode!;
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
    if (_errors.isNotEmpty) return;
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
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) {
        if (_submitted) setState(() => _errors = _validate());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final weightUnit = _unit == 'g' || _unit == 'ml';
    final p = widget.prefill;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.edit != null ? 'Edit food' : 'Create food'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
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
          ...spaced([
            TextField(
              key: const Key('food-name'),
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Name *',
                errorText: _errors['name'],
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_submitted) setState(() => _errors = _validate());
              },
            ),
            TextField(
              controller: _brand,
              decoration: const InputDecoration(
                labelText: 'Brand (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: _barcode,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Barcode (optional)',
                errorText: _errors['barcode'],
                border: const OutlineInputBorder(),
              ),
            ),
            const SectionHeader(
              'Serving',
              subtitle: 'Nutrition values below are for one serving.',
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _num('servingSize', _size, 'Serving size *')),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 130,
                  child: DropdownButtonFormField<String>(
                    initialValue: _unit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final u in servingUnits)
                        DropdownMenuItem(value: u, child: Text(u)),
                    ],
                    onChanged: (u) => setState(() => _unit = u ?? 'g'),
                  ),
                ),
              ],
            ),
            if (!weightUnit)
              _num(
                'gramsPerServing',
                _grams,
                'Grams per serving (optional)',
                suffix: 'g',
                helper: 'Lets you log this food by weight too',
              ),
            const SectionHeader('Nutrition per serving'),
            _num('calories', _kcal, 'Calories *', suffix: 'kcal'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _num('protein', _protein, 'Protein *', suffix: 'g'),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: _num('carbs', _carbs, 'Carbs *', suffix: 'g')),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _num('fat', _fat, 'Fat *', suffix: 'g')),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _num('fiber', _fiber, 'Fiber (optional)', suffix: 'g'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Add to favorites'),
              value: _favorite,
              onChanged: (v) => setState(() => _favorite = v),
            ),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const Key('food-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(widget.edit != null ? 'Save changes' : 'Save food'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
