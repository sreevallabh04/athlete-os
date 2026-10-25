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

  Future<void> _save() async {
    final y = _yield;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the recipe a name');
      return;
    }
    if (y == null) {
      setState(() => _error = 'Servings must be a number above 0');
      return;
    }
    if (_ingredients.isEmpty) {
      setState(() => _error = 'Add at least one ingredient');
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
          servings: y,
          ingredients: _ingredients,
        );
      } else {
        await repo.create(
          name: _name.text,
          servings: y,
          ingredients: _ingredients,
        );
      }
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New recipe' : 'Edit recipe'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Recipe name',
              hintText: 'e.g. Paneer bhurji',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _servings,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Makes how many servings?',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          SectionHeader('Ingredients', action: 'Add', onAction: _addIngredient),
          if (_ingredients.isEmpty)
            EmptyState(
              compact: true,
              icon: Icons.kitchen_outlined,
              title: 'No ingredients yet',
              message: 'Add foods from your list with the amount used.',
              actionLabel: 'Add ingredient',
              onAction: _addIngredient,
            ),
          for (var i = 0; i < _ingredients.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_ingredients[i].name),
              subtitle: Text(
                '${amountLabel(_ingredients[i].servings, _ingredients[i].grams)}'
                ' · ${macroSummary(_ingredients[i].nutrients)}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              trailing: IconButton(
                tooltip: 'Remove ingredient',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() => _ingredients.removeAt(i)),
              ),
            ),
          if (perServing != null) ...[
            const SectionHeader('Per serving'),
            AppCard(
              child: Column(
                children: [
                  NutrientPreview(
                    nutrients: perServing,
                    estimate: _ingredients.any(
                      (i) => Verifications.isEstimate(i.verification),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Whole recipe: ${Fmt.kcal(total.calories)} · '
                    '${Fmt.grams(total.protein)} protein',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Save recipe'),
            ),
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
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter your foods',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: foods.when(
              loading: () => const LoadingState(),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
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
