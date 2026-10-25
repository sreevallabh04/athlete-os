import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../data/recipe_repository.dart';
import '../data/saved_meal_repository.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import 'custom_food_screen.dart';
import 'describe_meal_screen.dart';
import 'food_actions.dart';
import 'food_search_panel.dart';
import 'meal_photo_screen.dart';
import 'recipe_builder_screen.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';
import 'widgets/food_tiles.dart';

/// Add food: Search · Recent · Favorites · My foods · Meals · Quick add.
class AddFoodScreen extends ConsumerStatefulWidget {
  const AddFoodScreen({
    super.key,
    this.initialMeal,
    this.initialDate,
    this.initialQuery,
  });

  /// From the `meal` query parameter (breakfast|lunch|dinner|snack).
  final String? initialMeal;

  /// From the `date` query parameter (YYYY-MM-DD).
  final String? initialDate;

  /// From the `q` query parameter: free text (e.g. shared from another app)
  /// that opens the describe-meal parser pre-filled.
  final String? initialQuery;

  @override
  ConsumerState<AddFoodScreen> createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends ConsumerState<AddFoodScreen> {
  late MealType _meal;
  late String _date;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider).now();
    _meal = MealType.tryParse(widget.initialMeal) ?? MealType.forTime(now);
    final d = widget.initialDate;
    _date = d != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)
        ? d
        : LocalDates.key(now);
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                DescribeMealScreen(meal: _meal, date: _date, initialText: q),
          ),
        );
      });
    }
  }

  Future<void> _pickDate() async {
    final now = ref.read(clockProvider).now();
    final picked = await showDatePicker(
      context: context,
      initialDate: LocalDates.parse(_date),
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) setState(() => _date = LocalDates.key(picked));
  }

  @override
  Widget build(BuildContext context) {
    final today = LocalDates.key(ref.watch(clockProvider).now());
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Add food'),
          actions: [
            IconButton(
              tooltip: 'Scan barcode',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () =>
                  runBarcodeFlow(context, ref, meal: _meal, date: _date),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(112),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: MealPicker(
                          value: _meal,
                          onChanged: (m) => setState(() => _meal = m),
                        ),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.event, size: 18),
                        label: Text(friendlyDate(_date, today)),
                        onPressed: _pickDate,
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'Search'),
                    Tab(text: 'Recent'),
                    Tab(text: 'Favorites'),
                    Tab(text: 'My foods'),
                    Tab(text: 'Meals'),
                    Tab(text: 'Quick add'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            FoodSearchPanel(
              meal: _meal,
              date: _date,
              header: _SearchShortcuts(meal: _meal, date: _date),
            ),
            _RecentTab(meal: _meal, date: _date),
            _FoodListTab(
              provider: favoriteFoodsProvider,
              meal: _meal,
              date: _date,
              emptyTitle: 'No favorites yet',
              emptyMessage: 'Tap the star on any food to pin it here.',
            ),
            _FoodListTab(
              provider: myFoodsProvider,
              meal: _meal,
              date: _date,
              emptyTitle: 'No saved foods',
              emptyMessage:
                  'Foods you create, scan or pick from search are kept here.',
              manage: true,
            ),
            _MealsTab(meal: _meal, date: _date),
            _QuickAddTab(meal: _meal, date: _date),
          ],
        ),
      ),
    );
  }
}

class _SearchShortcuts extends ConsumerWidget {
  const _SearchShortcuts({required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        ActionChip(
          avatar: const Icon(Icons.qr_code_scanner, size: 18),
          label: const Text('Scan barcode'),
          onPressed: () => runBarcodeFlow(context, ref, meal: meal, date: date),
        ),
        ActionChip(
          avatar: const Icon(Icons.notes, size: 18),
          label: const Text('Describe meal'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DescribeMealScreen(meal: meal, date: date),
            ),
          ),
        ),
        ActionChip(
          avatar: const Icon(Icons.photo_camera_outlined, size: 18),
          label: const Text('Meal photo'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MealPhotoScreen(meal: meal, date: date),
            ),
          ),
        ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('Create food'),
          onPressed: () async {
            final food = await Navigator.of(context).push<Food>(
              MaterialPageRoute(builder: (_) => const CustomFoodScreen()),
            );
            if (food != null && context.mounted) {
              await logLocalFood(
                context,
                ref,
                food: food,
                meal: meal,
                date: date,
              );
            }
          },
        ),
      ],
    );
  }
}

Future<void> copyFromPreviousDay(
  BuildContext context,
  WidgetRef ref, {
  required MealType meal,
  required String date,
}) async {
  final from = LocalDates.addDays(date, -1);
  try {
    final n = await ref
        .read(foodLogRepositoryProvider)
        .copy(fromDate: from, toDate: date, fromMeal: meal, toMeal: meal);
    if (!context.mounted) return;
    showSnack(
      context,
      n == 0
          ? 'Nothing logged for ${meal.label.toLowerCase()} the day before'
          : 'Copied $n item${n == 1 ? '' : 's'} to ${meal.label}',
    );
  } catch (e) {
    if (context.mounted) showSnack(context, redactSecrets(e.toString()));
  }
}

class _RecentTab extends ConsumerWidget {
  const _RecentTab({required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(recentFoodsProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        AppCard(
          onTap: () =>
              copyFromPreviousDay(context, ref, meal: meal, date: date),
          child: Row(
            children: [
              const Icon(Icons.content_copy_outlined),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Copy ${meal.label.toLowerCase()} from the day before',
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        ...recents.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (list) => list.isEmpty
              ? [
                  const EmptyState(
                    icon: Icons.history,
                    title: 'No recent foods',
                    message: 'Foods you log will show up here.',
                  ),
                ]
              : [
                  for (final f in list)
                    FoodListTile(
                      food: f,
                      onTap: () => logLocalFood(
                        context,
                        ref,
                        food: f,
                        meal: meal,
                        date: date,
                      ),
                      onToggleFavorite: () => ref
                          .read(foodRepositoryProvider)
                          .setFavorite(f.id, !f.isFavorite),
                    ),
                ],
        ),
      ],
    );
  }
}

class _FoodListTab extends ConsumerWidget {
  const _FoodListTab({
    required this.provider,
    required this.meal,
    required this.date,
    required this.emptyTitle,
    required this.emptyMessage,
    this.manage = false,
  });

  final StreamProvider<List<Food>> provider;
  final MealType meal;
  final String date;
  final String emptyTitle;
  final String emptyMessage;
  final bool manage;

  Future<void> _manage(BuildContext context, WidgetRef ref, Food f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit food'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete food'),
              subtitle: const Text('Past log entries are kept'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') {
      await Navigator.of(context).push<Food>(
        MaterialPageRoute(builder: (_) => CustomFoodScreen(edit: f)),
      );
    } else if (action == 'delete') {
      await ref.read(foodRepositoryProvider).softDelete(f.id);
      if (context.mounted) showSnack(context, 'Deleted ${f.name}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foods = ref.watch(provider);
    return foods.when(
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(message: redactSecrets('$e')),
      data: (list) => ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          if (manage)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final food = await Navigator.of(context).push<Food>(
                    MaterialPageRoute(builder: (_) => const CustomFoodScreen()),
                  );
                  if (food != null && context.mounted) {
                    await logLocalFood(
                      context,
                      ref,
                      food: food,
                      meal: meal,
                      date: date,
                    );
                  }
                },
                icon: const Icon(Icons.add),
                label: const Text('Create food'),
              ),
            ),
          if (list.isEmpty)
            EmptyState(
              icon: Icons.inventory_2_outlined,
              title: emptyTitle,
              message: emptyMessage,
            ),
          for (final f in list)
            FoodListTile(
              food: f,
              onTap: () =>
                  logLocalFood(context, ref, food: f, meal: meal, date: date),
              onLongPress: manage ? () => _manage(context, ref, f) : null,
              onToggleFavorite: () => ref
                  .read(foodRepositoryProvider)
                  .setFavorite(f.id, !f.isFavorite),
            ),
          if (manage && list.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                'Long-press a food to edit or delete it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _MealsTab extends ConsumerWidget {
  const _MealsTab({required this.meal, required this.date});
  final MealType meal;
  final String date;

  Future<void> _logSaved(
    BuildContext context,
    WidgetRef ref,
    SavedMealWithItems m,
  ) async {
    try {
      final ids = await ref
          .read(savedMealRepositoryProvider)
          .logSavedMeal(
            ref.read(foodLogRepositoryProvider),
            m.meal.id,
            mealType: meal,
            localDate: date,
          );
      if (!context.mounted) return;
      final log = ref.read(foodLogRepositoryProvider);
      showSnack(
        context,
        'Logged "${m.meal.name}" to ${meal.label}',
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            for (final id in ids) {
              await log.softDelete(id);
            }
          },
        ),
      );
    } catch (e) {
      if (context.mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  Future<void> _logRecipe(
    BuildContext context,
    WidgetRef ref,
    RecipeWithIngredients r,
  ) async {
    final res = await showAmountSheet(
      context,
      title: r.recipe.name,
      subtitle: 'Recipe · makes ${Fmt.oneDp(r.recipe.servings)} servings',
      basis: ServingBasis(
        perServing: r.perServing,
        servingSize: 1,
        servingUnit: 'serving',
      ),
      verification: r.verification,
      origin: DataOrigin.calculated,
      initialMeal: meal,
    );
    if (res == null || !context.mounted) return;
    try {
      await ref
          .read(recipeRepositoryProvider)
          .logRecipe(
            ref.read(foodLogRepositoryProvider),
            r.recipe.id,
            servings: res.amount.value,
            mealType: res.meal ?? meal,
            localDate: date,
          );
      if (context.mounted) {
        showSnack(context, 'Logged ${r.recipe.name}');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  Future<void> _saveCurrentMeal(BuildContext context, WidgetRef ref) async {
    final entries = (await ref.read(foodLogRepositoryProvider).day(date))
        .where((e) => e.mealType == meal.key)
        .toList();
    if (!context.mounted) return;
    if (entries.isEmpty) {
      showSnack(context, 'Log some ${meal.label.toLowerCase()} items first');
      return;
    }
    final ctrl = TextEditingController(text: 'My ${meal.label.toLowerCase()}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save meal'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Name',
            helperText: '${entries.length} items from ${meal.label}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    await ref
        .read(savedMealRepositoryProvider)
        .createFromEntries(name, entries, mealType: meal);
    if (context.mounted) showSnack(context, 'Saved "$name"');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedMealsProvider);
    final recipes = ref.watch(recipesProvider);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _saveCurrentMeal(context, ref),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: Text('Save ${meal.label.toLowerCase()} as meal'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) => const RecipeBuilderScreen(),
                ),
              ),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('New recipe'),
            ),
          ],
        ),
        const SectionHeader(
          'Saved meals',
          subtitle: 'Tap to log every item in one go',
        ),
        ...saved.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (list) => list.isEmpty
              ? [
                  const EmptyState(
                    compact: true,
                    icon: Icons.bookmark_border,
                    title: 'No saved meals',
                    message: 'Log a meal, then save it here to reuse it.',
                  ),
                ]
              : [
                  for (final m in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      minTileHeight: 60,
                      title: Row(
                        children: [
                          Flexible(child: Text(m.meal.name)),
                          if (m.hasEstimates) ...[
                            const SizedBox(width: AppSpacing.xs),
                            const EstimateBadge(),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${m.items.length} items · ${macroSummary(m.total)}',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      trailing: FilledButton(
                        onPressed: () => _logSaved(context, ref, m),
                        child: const Text('Log'),
                      ),
                      onLongPress: () async {
                        await ref
                            .read(savedMealRepositoryProvider)
                            .softDelete(m.meal.id);
                        if (context.mounted) {
                          showSnack(context, 'Deleted "${m.meal.name}"');
                        }
                      },
                    ),
                ],
        ),
        const SectionHeader('Recipes', subtitle: 'Nutrition per serving'),
        ...recipes.when(
          loading: () => [const LoadingState()],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (list) => list.isEmpty
              ? [
                  const EmptyState(
                    compact: true,
                    icon: Icons.menu_book_outlined,
                    title: 'No recipes',
                    message: 'Build one from your foods with "New recipe".',
                  ),
                ]
              : [
                  for (final r in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      minTileHeight: 60,
                      title: Text(r.recipe.name),
                      subtitle: Text(
                        'Per serving: ${macroSummary(r.perServing)}',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      onTap: () => _logRecipe(context, ref, r),
                      trailing: IconButton(
                        tooltip: 'Edit recipe',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<bool>(
                            builder: (_) => RecipeBuilderScreen(existing: r),
                          ),
                        ),
                      ),
                      onLongPress: () async {
                        await ref
                            .read(recipeRepositoryProvider)
                            .softDelete(r.recipe.id);
                        if (context.mounted) {
                          showSnack(context, 'Deleted "${r.recipe.name}"');
                        }
                      },
                    ),
                ],
        ),
      ],
    );
  }
}

class _QuickAddTab extends ConsumerStatefulWidget {
  const _QuickAddTab({required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  ConsumerState<_QuickAddTab> createState() => _QuickAddTabState();
}

class _QuickAddTabState extends ConsumerState<_QuickAddTab> {
  final _name = TextEditingController();
  final _kcal = TextEditingController();
  final _p = TextEditingController();
  final _c = TextEditingController();
  final _f = TextEditingController();
  bool _exact = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _kcal, _p, _c, _f]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _d(TextEditingController c, {bool optional = true}) {
    final t = c.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return optional ? 0 : null;
    final v = double.tryParse(t);
    return v != null && v.isFinite && v >= 0 ? v : null;
  }

  Future<void> _submit() async {
    final kcal = _d(_kcal, optional: false);
    final p = _d(_p);
    final c = _d(_c);
    final f = _d(_f);
    if (kcal == null || kcal <= 0 || kcal > 10000) {
      setState(() => _error = 'Enter calories between 1 and 10,000');
      return;
    }
    if (p == null || c == null || f == null) {
      setState(() => _error = 'Macros must be numbers (or left empty)');
      return;
    }
    setState(() => _error = null);
    await ref
        .read(foodLogRepositoryProvider)
        .quickAdd(
          name: _name.text,
          nutrients: Nutrients(calories: kcal, protein: p, carbs: c, fat: f),
          mealType: widget.meal,
          localDate: widget.date,
          isEstimate: !_exact,
        );
    if (!mounted) return;
    for (final c in [_name, _kcal, _p, _c, _f]) {
      c.clear();
    }
    showSnack(context, 'Added to ${widget.meal.label}');
  }

  Widget _field(TextEditingController c, String label, String suffix) =>
      TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          border: const OutlineInputBorder(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        AppCard(
          onTap: () => copyFromPreviousDay(
            context,
            ref,
            meal: widget.meal,
            date: widget.date,
          ),
          child: Row(
            children: [
              const Icon(Icons.content_copy_outlined),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Copy ${widget.meal.label.toLowerCase()} from the day before',
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
        const SectionHeader(
          'Quick add',
          subtitle: 'For when you only know the calories',
        ),
        ...spaced([
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'e.g. Office canteen thali',
              border: OutlineInputBorder(),
            ),
          ),
          _field(_kcal, 'Calories *', 'kcal'),
          Row(
            children: [
              Expanded(child: _field(_p, 'Protein', 'g')),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _field(_c, 'Carbs', 'g')),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _field(_f, 'Fat', 'g')),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Exact values (from a label)'),
            subtitle: Text(
              _exact ? 'Saved as entered by you' : 'Saved as an ESTIMATE',
            ),
            value: _exact,
            onChanged: (v) => setState(() => _exact = v),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _submit,
              child: Text('Add to ${widget.meal.label}'),
            ),
          ),
        ]),
      ],
    );
  }
}
