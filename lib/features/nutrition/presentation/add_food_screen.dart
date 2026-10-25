import 'dart:math' as math;

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
import 'widgets/nutrition_hud.dart';

/// Add food: Search · Recent · Favorites · My foods · Meals · Quick add.
class AddFoodScreen extends ConsumerStatefulWidget {
  const AddFoodScreen({
    super.key,
    this.initialMeal,
    this.initialDate,
    this.initialQuery,
    this.initialTab = 0,
  });

  /// From the `meal` query parameter (breakfast|lunch|dinner|snack).
  final String? initialMeal;

  /// From the `date` query parameter (YYYY-MM-DD).
  final String? initialDate;

  /// From the `q` query parameter: free text (e.g. shared from another app)
  /// that opens the describe-meal parser pre-filled.
  final String? initialQuery;

  /// 0 Search · 1 Recent · 2 Favorites · 3 My foods · 4 Meals · 5 Quick add.
  final int initialTab;

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
    if (picked != null) {
      Haptics.selection();
      setState(() => _date = LocalDates.key(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final hud = context.hud;
    final scaler = MediaQuery.textScalerOf(context);
    return DefaultTabController(
      length: 6,
      initialIndex: widget.initialTab.clamp(0, 5),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Add food'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: HudChip(
                label: friendlyDate(_date, today),
                icon: Icons.event_rounded,
                selected: _date != today,
                onTap: _pickDate,
              ),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(
              math.max(64, scaler.scale(50)) + AppSpacing.sm + 46,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    0,
                    AppSpacing.gutter,
                    AppSpacing.sm,
                  ),
                  child: MealPicker(
                    value: _meal,
                    onChanged: (m) => setState(() => _meal = m),
                  ),
                ),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: hud.hairline.withValues(alpha: 0.1),
                  onTap: (_) => Haptics.selection(),
                  tabs: const [
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
              emptyIcon: Icons.star_outline_rounded,
              emptyTitle: 'No favorites yet',
              emptyMessage: 'Tap the star on any food to pin it here.',
            ),
            _FoodListTab(
              provider: myFoodsProvider,
              meal: _meal,
              date: _date,
              emptyIcon: Icons.inventory_2_outlined,
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

/// Bottom padding for tab lists (keyboard / gesture bar safe).
EdgeInsets _listPadding(BuildContext context) => EdgeInsets.fromLTRB(
  AppSpacing.gutter,
  AppSpacing.md,
  AppSpacing.gutter,
  MediaQuery.paddingOf(context).bottom + AppSpacing.xxxl,
);

class _SearchShortcuts extends ConsumerWidget {
  const _SearchShortcuts({required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _ShortcutTile(
            icon: Icons.qr_code_scanner_rounded,
            label: 'Scan barcode',
            onTap: () => runBarcodeFlow(context, ref, meal: meal, date: date),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _ShortcutTile(
            icon: Icons.notes_rounded,
            label: 'Describe meal',
            ai: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DescribeMealScreen(meal: meal, date: date),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _ShortcutTile(
            icon: Icons.photo_camera_outlined,
            label: 'Meal photo',
            ai: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MealPhotoScreen(meal: meal, date: date),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _ShortcutTile(
            icon: Icons.add_box_outlined,
            label: 'Create food',
            onTap: () async {
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
        ),
      ],
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.ai = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool ai;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: ai ? '$label, AI assisted' : label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        pressedScale: 0.93,
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: hud.glassFill,
            border: Border.all(color: hud.hairline.withValues(alpha: 0.16)),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlowIcon(icon, size: 22),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: t.labelMedium?.copyWith(color: hud.text),
                  ),
                ],
              ),
              if (ai)
                Positioned(
                  top: -6,
                  right: -0,
                  child: Text(
                    'AI',
                    style: AppTypography.hudLabel(AppColors.warning, size: 9),
                  ),
                ),
            ],
          ),
        ),
      ),
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
    if (n > 0) Haptics.success();
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

class _CopyCard extends ConsumerWidget {
  const _CopyCard({required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    return AppCard(
      onTap: () => copyFromPreviousDay(context, ref, meal: meal, date: date),
      semanticLabel: 'Copy ${meal.label.toLowerCase()} from the day before',
      child: Row(
        children: [
          const GlowIcon(Icons.content_copy_rounded, size: 18, framed: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Copy ${meal.label.toLowerCase()} from the day before',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
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
      padding: _listPadding(context),
      children: [
        _CopyCard(meal: meal, date: date),
        const SizedBox(height: AppSpacing.lg),
        ...recents.when(
          loading: () => [const ScanlineLoader(lines: 4)],
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
                  HudCaption('Recently logged · ${list.length}'),
                  const SizedBox(height: AppSpacing.sm),
                  ...staggered([
                    for (final f in list)
                      FoodListTile(
                        key: ValueKey('recent-${f.id}'),
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
                  ]),
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
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    this.manage = false,
  });

  final StreamProvider<List<Food>> provider;
  final MealType meal;
  final String date;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final bool manage;

  Future<void> _manage(BuildContext context, WidgetRef ref, Food f) async {
    Haptics.medium();
    final action = await showHudBottomSheet<String>(
      context,
      title: f.name,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit food'),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppColors.red),
            title: const Text('Delete food'),
            subtitle: const Text('Past log entries are kept'),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') {
      await Navigator.of(context).push<Food>(
        MaterialPageRoute(builder: (_) => CustomFoodScreen(edit: f)),
      );
    } else if (action == 'delete') {
      Haptics.heavy();
      await ref.read(foodRepositoryProvider).softDelete(f.id);
      if (context.mounted) showSnack(context, 'Deleted ${f.name}');
    }
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final food = await Navigator.of(
      context,
    ).push<Food>(MaterialPageRoute(builder: (_) => const CustomFoodScreen()));
    if (food != null && context.mounted) {
      await logLocalFood(context, ref, food: food, meal: meal, date: date);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foods = ref.watch(provider);
    return foods.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.gutter),
        child: ScanlineLoader(lines: 4),
      ),
      error: (e, _) => ErrorState(message: redactSecrets('$e')),
      data: (list) => ListView(
        padding: _listPadding(context),
        children: [
          if (manage) ...[
            HudButton.secondary(
              label: 'Create food',
              icon: Icons.add_rounded,
              expand: true,
              onPressed: () => _create(context, ref),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (list.isEmpty)
            EmptyState(
              icon: emptyIcon,
              title: emptyTitle,
              message: emptyMessage,
            ),
          ...staggered([
            for (final f in list)
              FoodListTile(
                key: ValueKey('food-${f.id}'),
                food: f,
                onTap: () =>
                    logLocalFood(context, ref, food: f, meal: meal, date: date),
                onLongPress: manage ? () => _manage(context, ref, f) : null,
                onToggleFavorite: () => ref
                    .read(foodRepositoryProvider)
                    .setFavorite(f.id, !f.isFavorite),
              ),
          ]),
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
      Haptics.success();
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
      Haptics.warning();
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
    Haptics.success();
    if (context.mounted) showSnack(context, 'Saved "$name"');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedMealsProvider);
    final recipes = ref.watch(recipesProvider);
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: _listPadding(context),
      children: [
        Row(
          children: [
            Expanded(
              child: HudButton.secondary(
                label: 'Save ${meal.label.toLowerCase()}',
                icon: Icons.bookmark_add_outlined,
                compact: true,
                expand: true,
                onPressed: () => _saveCurrentMeal(context, ref),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: HudButton.secondary(
                label: 'New recipe',
                icon: Icons.menu_book_outlined,
                compact: true,
                expand: true,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => const RecipeBuilderScreen(),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SectionHeader('Saved meals', subtitle: 'Log every item at once'),
        ...saved.when(
          loading: () => [const ScanlineLoader(lines: 3)],
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
              : staggered([
                  for (final m in list)
                    Padding(
                      key: ValueKey('saved-${m.meal.id}'),
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        semanticLabel: m.meal.name,
                        onLongPress: () async {
                          Haptics.heavy();
                          await ref
                              .read(savedMealRepositoryProvider)
                              .softDelete(m.meal.id);
                          if (context.mounted) {
                            showSnack(context, 'Deleted "${m.meal.name}"');
                          }
                        },
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
                                          m.meal.name,
                                          style: t.titleSmall,
                                        ),
                                      ),
                                      if (m.hasEstimates) ...[
                                        const SizedBox(width: AppSpacing.xs),
                                        const EstimateBadge(),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${m.items.length} items · '
                                    '${macroSummary(m.total)}',
                                    style: t.bodySmall?.copyWith(
                                      color: hud.textMuted,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  FractionallySizedBox(
                                    widthFactor: 0.6,
                                    child: MacroSplitBar(
                                      protein: m.total.protein,
                                      carbs: m.total.carbs,
                                      fat: m.total.fat,
                                      height: 3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            HudButton(
                              label: 'Log',
                              compact: true,
                              onPressed: () => _logSaved(context, ref, m),
                            ),
                          ],
                        ),
                      ),
                    ),
                ]),
        ),
        const SectionHeader('Recipes', subtitle: 'Nutrition per serving'),
        ...recipes.when(
          loading: () => [const ScanlineLoader(lines: 3)],
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
              : staggered([
                  for (final r in list)
                    Padding(
                      key: ValueKey('recipe-${r.recipe.id}'),
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        semanticLabel: r.recipe.name,
                        onTap: () => _logRecipe(context, ref, r),
                        onLongPress: () async {
                          Haptics.heavy();
                          await ref
                              .read(recipeRepositoryProvider)
                              .softDelete(r.recipe.id);
                          if (context.mounted) {
                            showSnack(context, 'Deleted "${r.recipe.name}"');
                          }
                        },
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.md,
                          AppSpacing.xs,
                          AppSpacing.md,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.recipe.name, style: t.titleSmall),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Per serving: ${macroSummary(r.perServing)}',
                                    style: t.bodySmall?.copyWith(
                                      color: hud.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit recipe',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<bool>(
                                  builder: (_) =>
                                      RecipeBuilderScreen(existing: r),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ]),
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
      Haptics.warning();
      setState(() => _error = 'Enter calories between 1 and 10,000');
      return;
    }
    if (p == null || c == null || f == null) {
      Haptics.warning();
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
    Haptics.success();
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
        decoration: InputDecoration(labelText: label, suffixText: suffix),
        onChanged: (_) => setState(() {}),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final kcal = _d(_kcal, optional: false);
    return ListView(
      padding: _listPadding(context),
      children: [
        _CopyCard(meal: widget.meal, date: widget.date),
        const SectionHeader('Quick add', subtitle: 'Only know the calories?'),
        AppCard(
          accent: _exact ? null : AppColors.warning,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'e.g. Office canteen thali',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _field(_kcal, 'Calories *', 'kcal'),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(child: _field(_p, 'Protein', 'g')),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: _field(_c, 'Carbs', 'g')),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: _field(_f, 'Fat', 'g')),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Exact values (from a label)',
                          style: t.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        _exact
                            ? Text(
                                'Saved as entered by you',
                                style: t.bodySmall?.copyWith(
                                  color: hud.textMuted,
                                ),
                              )
                            : Row(
                                children: [
                                  Text(
                                    'Saved as an ',
                                    style: t.bodySmall?.copyWith(
                                      color: hud.textMuted,
                                    ),
                                  ),
                                  const EstimateBadge(),
                                ],
                              ),
                      ],
                    ),
                  ),
                  HudToggle(
                    value: _exact,
                    semanticLabel: 'Exact values from a label',
                    onChanged: (v) => setState(() => _exact = v),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  style: t.bodyMedium?.copyWith(color: AppColors.red),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              HudButton(
                label: kcal == null || kcal <= 0
                    ? 'Add to ${widget.meal.label}'
                    : 'Add ${Fmt.kcal(kcal)} to ${widget.meal.label}',
                icon: Icons.bolt_rounded,
                expand: true,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
