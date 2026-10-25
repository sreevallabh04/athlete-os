import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../../onboarding/presentation/meal_ideas_sheet.dart';
import '../application/providers.dart';
import '../data/mappers.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';
import 'add_food_screen.dart';
import 'describe_meal_screen.dart';
import 'food_actions.dart';
import 'meal_photo_screen.dart';
import 'widgets/common.dart';
import 'widgets/day_strip.dart';
import 'widgets/edit_entry_sheet.dart';
import 'widgets/nutrition_hud.dart';
import 'widgets/quick_add_fab.dart';

/// Entries swiped away but not yet removed by the database stream. Keeps
/// [Dismissible] happy (it must leave the tree synchronously).
class _HiddenEntries extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void hide(String id) => state = {...state, id};
  void show(String id) => state = {...state}..remove(id);
}

final _hiddenEntriesProvider = NotifierProvider<_HiddenEntries, Set<String>>(
  _HiddenEntries.new,
);

/// Shared hero tag between the Nutrition water card and Hydration.
const hydrationHeroTag = 'hydration-reactor';

/// Nutrition tab: macro reactor, day scrubber, meal timeline, water and a
/// speed-dial for every way of logging food.
class NutritionScreen extends ConsumerStatefulWidget {
  const NutritionScreen({super.key});

  @override
  ConsumerState<NutritionScreen> createState() => _NutritionScreenState();
}

class _NutritionScreenState extends ConsumerState<NutritionScreen> {
  late final GoalPulse _protein = GoalPulse(
    'protein',
    onFired: () {
      if (!mounted) return;
      showSnack(context, 'Protein target reached. Nicely done.');
    },
  );
  late final GoalPulse _water = GoalPulse(
    'water',
    onFired: () {
      if (!mounted) return;
      showSnack(context, 'Water goal reached for today.');
    },
  );

  @override
  void dispose() {
    _protein.dispose();
    _water.dispose();
    super.dispose();
  }

  String get _today => LocalDates.key(ref.read(clockProvider).now());

  MealType _defaultMeal(String date) => date == _today
      ? MealType.forTime(ref.read(clockProvider).now())
      : MealType.lunch;

  void _openAdd({MealType? meal, required String date, int tab = 0}) {
    if (tab == 0) {
      final params = {'date': date, 'meal': ?meal?.key};
      context.push(
        Uri(path: AppPaths.addFood, queryParameters: params).toString(),
      );
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AddFoodScreen(
          initialMeal: (meal ?? _defaultMeal(date)).key,
          initialDate: date,
          initialTab: tab,
        ),
      ),
    );
  }

  void _shiftDay(String date, int days) {
    final next = LocalDates.addDays(date, days);
    if (next.compareTo(_today) > 0) {
      Haptics.light();
      return;
    }
    Haptics.selection();
    ref.read(nutritionDateProvider.notifier).set(next);
  }

  List<QuickAction> _actions(String date) {
    final meal = _defaultMeal(date);
    final root = Navigator.of(context, rootNavigator: true);
    return [
      QuickAction(
        icon: Icons.search_rounded,
        label: 'Search food',
        onSelected: () => _openAdd(meal: meal, date: date),
      ),
      QuickAction(
        icon: Icons.qr_code_scanner_rounded,
        label: 'Scan barcode',
        onSelected: () => runBarcodeFlow(context, ref, meal: meal, date: date),
      ),
      QuickAction(
        icon: Icons.notes_rounded,
        label: 'Describe meal',
        ai: true,
        onSelected: () => root.push(
          MaterialPageRoute<void>(
            builder: (_) => DescribeMealScreen(meal: meal, date: date),
          ),
        ),
      ),
      QuickAction(
        icon: Icons.photo_camera_outlined,
        label: 'Meal photo',
        ai: true,
        onSelected: () => root.push(
          MaterialPageRoute<void>(
            builder: (_) => MealPhotoScreen(meal: meal, date: date),
          ),
        ),
      ),
      QuickAction(
        icon: Icons.bolt_rounded,
        label: 'Quick add calories',
        onSelected: () => _openAdd(meal: meal, date: date, tab: 5),
      ),
      QuickAction(
        icon: Icons.bookmark_outline_rounded,
        label: 'Saved meals & recipes',
        onSelected: () => _openAdd(meal: meal, date: date, tab: 4),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final date = ref.watch(nutritionDateProvider);
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final entries = ref.watch(dayEntriesProvider(date));
    final targets = ref.watch(nutritionTargetsProvider);
    final hidden = ref.watch(_hiddenEntriesProvider);
    final settings = ref.read(settingsRepositoryProvider);

    // Goal crossings on today's data arm a once-per-day celebration that
    // plays as soon as this screen is on stage.
    ref.listen<AsyncValue<List<FoodLogEntry>>>(dayEntriesProvider(today), (
      prev,
      next,
    ) {
      final before = prev?.value;
      final after = next.value;
      final target = ref.read(nutritionTargetsProvider).value?.protein ?? 0;
      if (before == null || after == null || target <= 0) return;
      double sum(List<FoodLogEntry> l) => l.fold(0.0, (a, e) => a + e.proteinG);
      if (sum(before) < target && sum(after) >= target) _protein.arm(today);
    });
    ref.listen<AsyncValue<List<WaterLog>>>(waterDayProvider(today), (
      prev,
      next,
    ) {
      final before = prev?.value;
      final after = next.value;
      final goal = ref.read(profileProvider).value?.waterGoalMl ?? 0;
      if (before == null || after == null || goal <= 0) return;
      int sum(List<WaterLog> l) => l.fold(0, (a, w) => a + w.amountMl);
      if (sum(before) < goal && sum(after) >= goal) _water.arm(today);
    });
    _protein.maybeFire(context, settings, visible: date == today);
    _water.maybeFire(context, settings, visible: date == today);

    final d = LocalDates.parse(date);
    return AppPage(
      title: 'Nutrition',
      eyebrow:
          '${DateFormat('EEE d MMM').format(d).toUpperCase()} · '
          '${date == today ? 'FUEL LOG' : friendlyDate(date, today).toUpperCase()}',
      actions: [
        IconButton(
          tooltip: 'Nutrition history',
          icon: const Icon(Icons.insights_outlined),
          onPressed: () => context.push(AppPaths.nutritionHistory),
        ),
      ],
      // Scaffold places FABs above the system inset only; lift it over the
      // floating dock too (MediaQuery.padding includes the dock).
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
          bottom: math.max(
            0,
            MediaQuery.paddingOf(context).bottom -
                MediaQuery.viewPaddingOf(context).bottom,
          ),
        ),
        child: QuickAddFab(actions: _actions(date)),
      ),
      children: [
        _StripSection(today: today, date: date),
        const SizedBox(height: AppSpacing.md),
        ...entries.when(
          loading: () => [const ScanlineLoader(height: 360, lines: 0)],
          error: (e, _) => [
            ErrorState(
              message: redactSecrets('$e'),
              onRetry: () => ref.invalidate(dayEntriesProvider(date)),
            ),
          ],
          data: (all) {
            final list = all.where((e) => !hidden.contains(e.id)).toList();
            final totals = DayTotals.fromLines(list.map((e) => e.line));
            return targets.when(
              loading: () => [const ScanlineLoader(height: 360, lines: 0)],
              error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
              data: (t) {
                final proteinLeft = t.protein - totals.total.protein;
                return [
                  _ReactorCard(
                    totals: totals,
                    targets: t,
                    date: date,
                    today: today,
                    burst: _protein.burst,
                    onSwipe: (dir) => _shiftDay(date, dir),
                  ),
                  if (totals.estimateCount > 0) ...[
                    const SizedBox(height: AppSpacing.md),
                    NoticeBanner(
                      icon: Icons.auto_awesome_outlined,
                      color: AppColors.warning,
                      message:
                          'Includes ${totals.estimateCount} estimated '
                          'item${totals.estimateCount == 1 ? '' : 's'}. '
                          'Totals are approximate.',
                    ),
                  ],
                  if (date == today && proteinLeft > 0) ...[
                    const SizedBox(height: AppSpacing.md),
                    MealIdeasCard(
                      kcalLeft: t.calories - totals.total.calories,
                      proteinLeft: proteinLeft,
                    ),
                  ],
                  SectionHeader(
                    'Meals',
                    subtitle: totals.isEmpty
                        ? (date == today
                              ? 'Nothing logged yet today'
                              : 'Nothing logged on this day')
                        : '${totals.entryCount} '
                              'item${totals.entryCount == 1 ? '' : 's'} · '
                              '${Fmt.kcal(totals.total.calories)}',
                  ),
                  _MealTimeline(
                    date: date,
                    nextMeal: date == today ? MealType.forTime(now) : null,
                    entries: list,
                    totals: totals,
                    onAdd: (m) => _openAdd(meal: m, date: date),
                  ),
                ];
              },
            );
          },
        ),
        const SectionHeader('Hydration'),
        _WaterCard(date: date, isToday: date == today, burst: _water.burst),
        const SizedBox(height: AppSpacing.md),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _LinkTile(
                  icon: Icons.insights_outlined,
                  label: 'History & trends',
                  onTap: () => context.push(AppPaths.nutritionHistory),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _LinkTile(
                  icon: Icons.tune_rounded,
                  label: 'Edit targets',
                  onTap: () => context.push(AppPaths.profile),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Day strip
// ---------------------------------------------------------------------------

class _StripSection extends ConsumerWidget {
  const _StripSection({required this.today, required this.date});
  final String today;
  final String date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const days = 28;
    final start = LocalDates.addDays(today, -(days - 1));
    final history = ref.watch(nutritionHistoryProvider((start, today))).value;
    final target = ref.watch(nutritionTargetsProvider).value?.calories ?? 0;
    final progress = <String, double>{
      if (history != null && target > 0)
        for (final d in history.days)
          if (d.hasLogs) d.localDate: d.total.calories / target,
    };
    return DayStrip(
      today: today,
      selected: date,
      days: days,
      progress: progress,
      onSelect: ref.read(nutritionDateProvider.notifier).set,
    );
  }
}

// ---------------------------------------------------------------------------
// Reactor hero
// ---------------------------------------------------------------------------

class _ReactorCard extends StatelessWidget {
  const _ReactorCard({
    required this.totals,
    required this.targets,
    required this.date,
    required this.today,
    required this.burst,
    required this.onSwipe,
  });

  final DayTotals totals;
  final NutritionTargets targets;
  final String date;
  final String today;
  final CelebrationController burst;
  final ValueChanged<int> onSwipe;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final consumed = totals.total;
    final rem = RemainingSummary.compute(consumed, targets);
    final kcal = rem.calories;
    final over = kcal.isOver;
    final ringLabel = !kcal.hasTarget
        ? 'No calorie target set'
        : over
        ? 'Over by ${Fmt.kcal(kcal.overBy)}'
        : '${Fmt.kcal(kcal.value!)} remaining';
    final values = ReactorValues(
      calories: kcal.ratio,
      protein: rem.protein.ratio,
      carbs: rem.carbs.ratio,
      fat: rem.fat.ratio,
    );
    final center = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedTicker(
          kcal.hasTarget
              ? Fmt.integer(over ? kcal.overBy : kcal.value!)
              : Fmt.integer(consumed.calories),
          style: hud.number(size: 46, color: over ? overColor : hud.text),
        ),
        const SizedBox(height: 2),
        Text(
          !kcal.hasTarget
              ? 'KCAL EATEN'
              : over
              ? 'KCAL OVER'
              : 'KCAL LEFT',
          style: hud.label(size: 11.5, color: over ? overColor : null),
        ),
        const SizedBox(height: 6),
        Text(
          '${Fmt.integer(consumed.calories)} / '
          '${kcal.hasTarget ? Fmt.integer(targets.calories) : '—'}',
          style: hud.mono(size: 10.5),
        ),
      ],
    );

    return Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Previous day'): () => onSwipe(-1),
        if (date != today)
          const CustomSemanticsAction(label: 'Next day'): () => onSwipe(1),
      },
      child: GestureDetector(
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 300) onSwipe(-1);
          if (v < -300) onSwipe(1);
        },
        child: AppCard(
          accent: AppColors.calories,
          brackets: true,
          semanticLabel:
              '${Fmt.kcal(consumed.calories)} eaten. $ringLabel. '
              'Target ${Fmt.kcal(targets.calories)}. Swipe to change day.',
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, box) {
                  final size = box.maxWidth.clamp(200.0, 270.0);
                  return CelebrationBurst(
                    controller: burst,
                    color: AppColors.protein,
                    spread: 1.1,
                    child: MacroReactor(
                      size: size,
                      values: values,
                      center: center,
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MacroTile(
                      label: 'Protein',
                      color: AppColors.protein,
                      r: rem.protein,
                      goal: true,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _MacroTile(
                      label: 'Carbs',
                      color: AppColors.carbs,
                      r: rem.carbs,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _MacroTile(
                      label: 'Fat',
                      color: AppColors.fat,
                      r: rem.fat,
                    ),
                  ),
                ],
              ),
              if (targets.fiber != null && targets.fiber! > 0) ...[
                const SizedBox(height: AppSpacing.md),
                MetricBar(
                  label: 'Fiber',
                  value: consumed.fiber ?? 0,
                  target: targets.fiber!,
                  color: AppColors.fiber,
                  unit: ' g',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MacroTile extends StatelessWidget {
  const _MacroTile({
    required this.label,
    required this.color,
    required this.r,
    this.goal = false,
  });

  final String label;
  final Color color;
  final Remaining r;

  /// Hitting this target is an achievement (protein), not a limit.
  final bool goal;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final hit = goal && r.hasTarget && r.consumed >= r.target!;
    final over = !goal && r.isOver;
    final status = !r.hasTarget
        ? 'no target'
        : hit
        ? 'target hit'
        : over
        ? 'over ${Fmt.grams(r.overBy)}'
        : '${Fmt.grams(r.value!)} left';
    final statusColor = hit
        ? AppColors.gold
        : over
        ? overColor
        : hud.textMuted;
    return Semantics(
      label:
          '$label ${Fmt.grams(r.consumed)}'
          '${r.hasTarget ? ' of ${Fmt.grams(r.target!)}' : ''}, $status',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          color: color.withValues(alpha: hud.isDark ? 0.06 : 0.08),
          border: Border.all(
            color: (hit ? AppColors.gold : color).withValues(
              alpha: hit ? 0.55 : 0.2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.8 * hud.glowStrength),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: t.labelMedium?.copyWith(color: hud.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  AnimatedTicker(
                    Fmt.integer(r.consumed),
                    style: hud.number(size: 24),
                  ),
                  Text(
                    r.hasTarget ? ' / ${Fmt.integer(r.target!)}' : ' g',
                    style: hud.mono(size: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (hit) ...[
                  Icon(
                    Icons.military_tech_rounded,
                    size: 13,
                    color: AppColors.gold,
                    shadows: AppGlows.text(
                      AppColors.gold,
                      strength: hud.glowStrength,
                    ),
                  ),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    status,
                    style: t.labelSmall?.copyWith(
                      color: hud.isDark || statusColor == hud.textMuted
                          ? statusColor
                          : hud.text,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

// ---------------------------------------------------------------------------
// Meal timeline
// ---------------------------------------------------------------------------

class _MealTimeline extends StatelessWidget {
  const _MealTimeline({
    required this.date,
    required this.nextMeal,
    required this.entries,
    required this.totals,
    required this.onAdd,
  });

  final String date;
  final MealType? nextMeal;
  final List<FoodLogEntry> entries;
  final DayTotals totals;
  final ValueChanged<MealType> onAdd;

  @override
  Widget build(BuildContext context) {
    final meals = MealType.values;
    return StaggeredList(
      children: [
        for (var i = 0; i < meals.length; i++)
          _MealNode(
            meal: meals[i],
            date: date,
            first: i == 0,
            last: i == meals.length - 1,
            upNext:
                meals[i] == nextMeal &&
                entries.every((e) => e.mealType != meals[i].key),
            entries: entries.where((e) => e.mealType == meals[i].key).toList(),
            total: totals.byMeal[meals[i]]!,
            onAdd: () => onAdd(meals[i]),
          ),
      ],
    );
  }
}

class _MealNode extends ConsumerWidget {
  const _MealNode({
    required this.meal,
    required this.date,
    required this.first,
    required this.last,
    required this.upNext,
    required this.entries,
    required this.total,
    required this.onAdd,
  });

  final MealType meal;
  final String date;
  final bool first;
  final bool last;
  final bool upNext;
  final List<FoodLogEntry> entries;
  final Nutrients total;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final filled = entries.isNotEmpty;
    final nodeColor = filled
        ? AppColors.calories
        : (upNext ? hud.accent : hud.textMuted);
    final firstAt = filled
        ? entries.map((e) => e.loggedAt).reduce((a, b) => a.isBefore(b) ? a : b)
        : null;

    final header = Row(
      children: [
        Icon(
          mealIcon(meal),
          size: 18,
          color: filled ? hud.text : hud.textMuted,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Semantics(
                  header: true,
                  child: Text(
                    meal.label,
                    style: t.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (upNext) ...[
                const SizedBox(width: AppSpacing.sm),
                const Flexible(
                  child: HudChip(label: 'Up next', dot: true, selected: true),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        if (filled)
          Text(
            Fmt.kcal(total.calories),
            style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        if (filled)
          PopupMenuButton<String>(
            tooltip: '${meal.label} options',
            icon: Icon(Icons.more_horiz_rounded, color: hud.textMuted),
            onSelected: (v) {
              if (v == 'copy') {
                copyFromPreviousDay(context, ref, meal: meal, date: date);
              } else if (v == 'add') {
                onAdd();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'add',
                child: Text('Add to ${meal.label.toLowerCase()}'),
              ),
              PopupMenuItem(
                value: 'copy',
                child: Text('Copy ${meal.label.toLowerCase()} from yesterday'),
              ),
            ],
          ),
      ],
    );

    final Widget body;
    if (!filled) {
      body = _EmptySlot(
        meal: meal,
        highlight: upNext,
        header: header,
        onAdd: onAdd,
        onCopy: () => copyFromPreviousDay(context, ref, meal: meal, date: date),
      );
    } else {
      body = AppCard(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 48, child: header),
            Padding(
              padding: const EdgeInsets.only(
                right: AppSpacing.md,
                bottom: AppSpacing.xs,
              ),
              child: Text(
                '${firstAt == null ? '' : '${Fmt.time(firstAt).toUpperCase()} · '}'
                'P ${Fmt.grams(total.protein)} · C ${Fmt.grams(total.carbs)}'
                ' · F ${Fmt.grams(total.fat)}',
                style: hud.mono(size: 10.5),
              ),
            ),
            for (final e in entries) _EntryRow(entry: e),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text('Add to ${meal.label.toLowerCase()}'),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.md),
      child: Stack(
        children: [
          // Rail.
          Positioned(
            left: 9,
            top: first ? 24 : -AppSpacing.md,
            bottom: last ? null : 0,
            height: last ? 24 : null,
            width: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    hud.hairline.withValues(alpha: 0.18),
                    hud.hairline.withValues(alpha: 0.06),
                  ],
                ),
              ),
            ),
          ),
          // Node.
          Positioned(
            left: 2,
            top: 17,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled
                    ? nodeColor
                    : nodeColor.withValues(alpha: upNext ? 0.18 : 0.06),
                border: Border.all(
                  color: nodeColor.withValues(alpha: filled ? 1 : 0.7),
                  width: 1.5,
                ),
                boxShadow: filled || upNext
                    ? AppGlows.soft(nodeColor, strength: hud.glowStrength)
                    : null,
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.only(left: 30), child: body),
        ],
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot({
    required this.meal,
    required this.highlight,
    required this.header,
    required this.onAdd,
    required this.onCopy,
  });

  final MealType meal;
  final bool highlight;
  final Widget header;
  final VoidCallback onAdd;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = highlight ? hud.accent : hud.hairline;
    return Semantics(
      container: true,
      label: '${meal.label}: nothing logged',
      child: CustomPaint(
        foregroundPainter: _DashedBorderPainter(
          color: c.withValues(alpha: highlight ? 0.55 : 0.22),
          radius: AppRadii.lg,
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadii.card,
            color: highlight
                ? hud.accent.withValues(alpha: 0.05)
                : hud.text.withValues(alpha: 0.015),
          ),
          padding: highlight
              ? const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.md,
                )
              : const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
          child: highlight
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 48, child: header),
                    Row(
                      children: [
                        Expanded(
                          child: HudButton(
                            label: 'Log ${meal.label.toLowerCase()}',
                            icon: Icons.add_rounded,
                            compact: true,
                            expand: true,
                            onPressed: onAdd,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        _CopyButton(meal: meal, onTap: onCopy),
                      ],
                    ),
                  ],
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Row(
                    children: [
                      Expanded(child: header),
                      _CopyButton(meal: meal, onTap: onCopy),
                      const SizedBox(width: AppSpacing.xs),
                      HudButton.secondary(
                        label: 'Add',
                        icon: Icons.add_rounded,
                        compact: true,
                        onPressed: onAdd,
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.meal, required this.onTap});
  final MealType meal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return IconButton(
      tooltip: 'Copy ${meal.label.toLowerCase()} from yesterday',
      onPressed: () {
        Haptics.light();
        onTap();
      },
      icon: Icon(Icons.content_copy_rounded, size: 20, color: hud.accentInk),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class _EntryRow extends ConsumerWidget {
  const _EntryRow({required this.entry});
  final FoodLogEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final estimate = Verifications.isEstimate(e.verification);
    final verified =
        e.verification == Verifications.verifiedLabel ||
        e.verification == Verifications.database;
    return Dismissible(
      key: ValueKey('entry-${e.id}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.35},
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          gradient: LinearGradient(
            colors: [
              AppColors.red.withValues(alpha: 0.0),
              AppColors.red.withValues(alpha: 0.35),
            ],
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('DELETE', style: hud.label(size: 11, color: AppColors.red)),
            const SizedBox(width: 6),
            const Icon(Icons.delete_outline, color: AppColors.red),
          ],
        ),
      ),
      onUpdate: (d) {
        if (d.reached && !d.previousReached) Haptics.medium();
      },
      onDismissed: (_) async {
        final log = ref.read(foodLogRepositoryProvider);
        final hidden = ref.read(_hiddenEntriesProvider.notifier);
        final messenger = ScaffoldMessenger.maybeOf(context);
        hidden.hide(e.id);
        await log.softDelete(e.id);
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Deleted ${e.name}'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  Haptics.light();
                  await log.restore(e.id);
                  hidden.show(e.id);
                },
              ),
            ),
          );
      },
      child: Semantics(
        button: true,
        label:
            '${e.name}, ${amountLabel(e.servings, e.grams)}, '
            '${Fmt.kcal(e.calories)}, protein ${Fmt.grams(e.proteinG)}'
            '${estimate ? ', estimate' : ''}. Tap to edit, swipe left to delete.',
        excludeSemantics: true,
        child: PressableScale(
          onTap: () => showEditEntrySheet(context, e),
          pressedScale: 0.98,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.only(
                right: AppSpacing.md,
                top: 6,
                bottom: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                e.name,
                                style: t.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (estimate)
                              const EstimateBadge()
                            else if (verified)
                              VerifiedGlyph(
                                label: Verifications.label(e.verification),
                                icon: Icons.verified_rounded,
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            amountLabel(e.servings, e.grams),
                            'P ${Fmt.grams(e.proteinG)}',
                            ?e.brand,
                          ].join(' · '),
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(Fmt.integer(e.calories), style: hud.number(size: 20)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Water + links
// ---------------------------------------------------------------------------

class _WaterCard extends ConsumerWidget {
  const _WaterCard({
    required this.date,
    required this.isToday,
    required this.burst,
  });
  final String date;
  final bool isToday;
  final CelebrationController burst;

  Future<void> _quickAdd(BuildContext context, WidgetRef ref) async {
    try {
      final repo = ref.read(waterRepositoryProvider);
      final id = await repo.add(250);
      Haptics.success();
      if (!context.mounted) return;
      showSnack(
        context,
        'Added 250 ml',
        action: SnackBarAction(label: 'Undo', onPressed: () => repo.remove(id)),
      );
    } catch (e) {
      if (context.mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(waterDayProvider(date));
    final profile = ref.watch(profileProvider);
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final goal = profile.value?.waterGoalMl ?? 0;
    final h = HydrationSummary.fromAmounts(
      (logs.value ?? const []).map((w) => w.amountMl),
      goal,
    );
    return AppCard(
      accent: AppColors.water,
      onTap: () => context.push(AppPaths.hydration),
      semanticLabel:
          'Water ${Fmt.ml(h.totalMl)} of ${Fmt.ml(goal)}. Open hydration.',
      child: Row(
        children: [
          CelebrationBurst(
            controller: burst,
            color: AppColors.water,
            spread: 1.6,
            child: Hero(
              tag: hydrationHeroTag,
              child: LiquidReactor(
                progress: h.visualProgress,
                size: 64,
                child: Text(
                  h.hasGoal ? '${(h.visualProgress * 100).round()}%' : '—',
                  style: hud
                      .number(size: 15, color: Colors.white)
                      .copyWith(
                        shadows: const [
                          Shadow(color: Color(0xCC04060B), blurRadius: 6),
                        ],
                      ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Water', style: t.titleMedium),
                const SizedBox(height: 2),
                Text(
                  logs.isLoading
                      ? 'Loading…'
                      : '${preciseMl(h.totalMl)} of ${preciseMl(goal)}'
                            '${h.goalReached ? ' · goal reached' : ''}',
                  style: t.bodyMedium?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
          if (isToday)
            Semantics(
              button: true,
              label: 'Add 250 millilitres of water',
              excludeSemantics: true,
              child: PressableScale(
                haptic: PressHaptic.none,
                onTap: () => _quickAdd(context, ref),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    color: AppColors.water.withValues(alpha: 0.12),
                    border: Border.all(
                      color: AppColors.water.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.water_drop_rounded,
                        size: 16,
                        color: hud.isDark ? AppColors.water : hud.accentInk,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '+250',
                        style: t.labelLarge?.copyWith(
                          color: hud.isDark ? hud.text : hud.accentInk,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return AppCard(
      onTap: onTap,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          GlowIcon(icon, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge,
              maxLines: 2,
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: hud.textMuted),
        ],
      ),
    );
  }
}
