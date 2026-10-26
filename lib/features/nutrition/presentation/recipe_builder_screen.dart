import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../data/mappers.dart';
import '../data/recipe_repository.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';
import 'custom_food_screen.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';
import 'widgets/food_tiles.dart';
import 'widgets/nutrition_hud.dart';

/// Build a recipe from local foods; per-serving nutrition is computed
/// deterministically from ingredient snapshots.
class RecipeBuilderScreen extends ConsumerStatefulWidget {
  const RecipeBuilderScreen({super.key, this.existing});
  final RecipeWithIngredients? existing;

  @override
  ConsumerState<RecipeBuilderScreen> createState() =>
      _RecipeBuilderScreenState();
}

class _RecipeBuilderScreenState extends ConsumerState<RecipeBuilderScreen> {
  final _name = TextEditingController();
  final _servings = TextEditingController(text: '1');
  final List<IngredientDraft> _ingredients = [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.recipe.name;
      _servings.text = plainNum(e.recipe.servings);
      _ingredients.addAll([
        for (final i in e.ingredients)
          IngredientDraft(
            name: i.name,
            foodId: i.foodId,
            servings: i.servings,
            grams: i.grams,
            nutrients: i.nutrients,
            verification: i.verification,
          ),
      ]);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _servings.dispose();
    super.dispose();
  }

  double? get _yield {
    final v = double.tryParse(_servings.text.trim().replaceAll(',', '.'));
    return v != null && v.isFinite && v > 0 ? v : null;
  }

  Future<void> _addIngredient() async {
    final food = await Navigator.of(
      context,
    ).push<Food>(MaterialPageRoute(builder: (_) => const FoodPickerScreen()));
    if (food == null || !mounted) return;
    final res = await showAmountSheet(
      context,
      title: food.name,
      subtitle: 'Amount used in the whole recipe',
      basis: food.basis,
      verification: food.verification,
      origin: originForSource(food.source),
      actionLabel: 'Add ingredient',
      initialAmount: food.basis.supportsGrams
          ? Amount.grams(food.basis.gramsPerServing!)
          : const Amount.servings(1),
    );
    if (res == null || !mounted) return;
    setState(
      () => _ingredients.add(IngredientDraft.fromFood(food, res.amount)),
    );
  }

  void _setYield(double v) => setState(() => _servings.text = plainNum(v));

  Future<void> _save() async {
    final y = _yield;
    String? error;
    if (_name.text.trim().isEmpty) {
      error = 'Give the recipe a name';
    } else if (y == null) {
      error = 'Servings must be a number above 0';
    } else if (_ingredients.isEmpty) {
      error = 'Add at least one ingredient';
    }
    if (error != null) {
      Haptics.warning();
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final repo = ref.read(recipeRepositoryProvider);
      if (widget.existing != null) {
        await repo.update(
          widget.existing!.recipe.id,
          name: _name.text,
          servings: y!,
          ingredients: _ingredients,
        );
      } else {
        await repo.create(
          name: _name.text,
          servings: y!,
          ingredients: _ingredients,
        );
      }
      Haptics.success();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = redactSecrets(e.toString());
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = _yield;
    final total = _ingredients.fold(Nutrients.zero, (a, i) => a + i.nutrients);
    final perServing = y == null || _ingredients.isEmpty
        ? null
        : recipePerServing(_ingredients.map((i) => i.nutrients), y);
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New recipe' : 'Edit recipe'),
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
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  style: t.titleMedium,
                  decoration: const InputDecoration(
                    labelText: 'Recipe name',
                    hintText: 'e.g. Paneer bhurji',
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('MAKES HOW MANY SERVINGS?', style: hud.label(size: 11)),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    for (final n in const [1.0, 2.0, 3.0, 4.0, 6.0]) ...[
                      HudChip(
                        label: Fmt.oneDp(n),
                        selected: y == n,
                        onTap: () => _setYield(n),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Expanded(
                      child: TextField(
                        controller: _servings,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                        ],
                        decoration: const InputDecoration(isDense: true),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionHeader(
            'Ingredients',
            subtitle: _ingredients.isEmpty
                ? null
                : '${_ingredients.length} · ${Fmt.kcal(total.calories)} total',
            action: 'Add',
            onAction: _addIngredient,
          ),
          if (_ingredients.isEmpty)
            AppCard(
              child: EmptyState(
                compact: true,
                icon: Icons.kitchen_outlined,
                title: 'No ingredients yet',
                message: 'Add foods from your list with the amount used.',
                actionLabel: 'Add ingredient',
                onAction: _addIngredient,
              ),
            )
          else
            AppCard(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.xs,
                AppSpacing.xs,
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _ingredients.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _ingredients[i].name,
                                        style: t.titleSmall,
                                      ),
                                    ),
                                    if (Verifications.isEstimate(
                                      _ingredients[i].verification,
                                    )) ...[
                                      const SizedBox(width: AppSpacing.xs),
                                      const EstimateBadge(),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${amountLabel(_ingredients[i].servings, _ingredients[i].grams)}'
                                  ' · ${macroSummary(_ingredients[i].nutrients)}',
                                  style: t.bodySmall?.copyWith(
                                    color: hud.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove ingredient',
                            icon: Icon(
                              Icons.remove_circle_outline,
                              color: hud.textMuted,
                            ),
                            onPressed: () {
                              Haptics.medium();
                              setState(() => _ingredients.removeAt(i));
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (perServing != null) ...[
            const SectionHeader('Per serving'),
            AppCard(
              accent: AppColors.calories,
              child: Column(
                children: [
                  NutrientPreview(
                    nutrients: perServing,
                    estimate: _ingredients.any(
                      (i) => Verifications.isEstimate(i.verification),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  MacroSplitBar(
                    protein: perServing.protein,
                    carbs: perServing.carbs,
                    fat: perServing.fat,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'WHOLE RECIPE · ${Fmt.kcal(total.calories).toUpperCase()}'
                    ' · ${Fmt.grams(total.protein).toUpperCase()} PROTEIN',
                    style: hud.mono(size: 10.5),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: t.bodyMedium?.copyWith(color: AppColors.danger),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          HudButton(
            label: 'Save recipe',
            icon: Icons.check_rounded,
            expand: true,
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

/// Picks a local food (with a shortcut to create one). Pops with [Food].
class FoodPickerScreen extends ConsumerStatefulWidget {
  const FoodPickerScreen({super.key});

  @override
  ConsumerState<FoodPickerScreen> createState() => _FoodPickerScreenState();
}

class _FoodPickerScreenState extends ConsumerState<FoodPickerScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final foods = ref.watch(myFoodsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a food'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final f = await Navigator.of(context).push<Food>(
                MaterialPageRoute(builder: (_) => const CustomFoodScreen()),
              );
              if (f != null && context.mounted) Navigator.of(context).pop(f);
            },
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.md,
            ),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: context.hud.accentInk,
                ),
                hintText: 'Filter your foods',
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: foods.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.gutter),
                child: ScanlineLoader(lines: 4),
              ),
              error: (e, _) => ErrorState(message: redactSecrets('$e')),
              data: (list) {
                final filtered = _q.isEmpty
                    ? list
                    : list
                          .where((f) => f.name.toLowerCase().contains(_q))
                          .toList();
                if (filtered.isEmpty) {
                  return const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'No foods',
                    message:
                        'Search or scan foods from the Add food screen, or '
                        'create one with "New".',
                  );
                }
                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    0,
                    AppSpacing.gutter,
                    MediaQuery.paddingOf(context).bottom + AppSpacing.xxl,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => FoodListTile(
                    food: filtered[i],
                    onTap: () => Navigator.of(context).pop(filtered[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
