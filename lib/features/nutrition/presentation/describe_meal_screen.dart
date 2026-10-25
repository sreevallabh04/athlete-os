import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../data/food_log_repository.dart';
import '../data/mappers.dart';
import '../domain/ai_contracts.dart';
import '../domain/food_models.dart';
import '../domain/nl_parser.dart';
import '../domain/nutrients.dart';
import 'food_search_panel.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';

/// Natural-language logging: "150 g paneer, 200 g rice and one banana".
/// A deterministic local parser matches items to the user's foods; anything
/// unmatched is listed as "needs lookup". AI estimation is an explicit,
/// clearly-labelled fallback that requires confirmation per item.
class DescribeMealScreen extends ConsumerStatefulWidget {
  const DescribeMealScreen({
    super.key,
    required this.meal,
    required this.date,
    this.initialText,
  });
  final MealType meal;
  final String date;

  /// Pre-filled description, e.g. text shared into the app.
  final String? initialText;

  @override
  ConsumerState<DescribeMealScreen> createState() => _DescribeMealScreenState();
}

class _Row {
  _Row(this.match) : include = match.status == MatchStatus.matched;
  FoodMatch match;
  bool include;
}

class _EstimateRow {
  _EstimateRow(this.item);
  final EstimatedFood item;
  bool confirmed = false;
}

const _examples = [
  '2 eggs, 2 rotis and 200 g dal',
  '150 g paneer and 200 g rice',
  '1 scoop whey and 1 banana',
];

class _DescribeMealScreenState extends ConsumerState<DescribeMealScreen> {
  late final _ctrl = TextEditingController(text: widget.initialText ?? '');
  late MealType _meal = widget.meal;
  List<_Row> _rows = const [];
  Map<String, Food> _foodsById = const {};
  bool _parsed = false;
  bool _busy = false;
  bool _aiBusy = false;
  String? _aiMessage;
  List<_EstimateRow> _estimates = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      Haptics.warning();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final repo = ref.read(foodRepositoryProvider);
    final recents = await repo.recents(limit: 50);
    final all = await repo.all();
    // Recents first so the user's usual foods win ties.
    final ordered = <Food>[
      ...recents,
      ...all.where((f) => !recents.contains(f)),
    ];
    final matches = matchParsedFoods(parseFoodText(text), [
      for (final f in ordered) f.ref,
    ]);
    if (!mounted) return;
    setState(() {
      _foodsById = {for (final f in ordered) f.id: f};
      _rows = [for (final m in matches) _Row(m)];
      _parsed = true;
      _busy = false;
      _aiMessage = null;
      _estimates = const [];
    });
    Haptics.selection();
  }

  Future<void> _chooseAmount(_Row row) async {
    final food = _foodsById[row.match.food!.id];
    if (food == null) return;
    final res = await showAmountSheet(
      context,
      title: food.name,
      subtitle: 'For "${row.match.item.raw}"',
      basis: food.basis,
      verification: food.verification,
      origin: originForSource(food.source),
      actionLabel: 'Use this amount',
      initialAmount: row.match.amount,
    );
    if (res == null || !mounted) return;
    setState(() {
      row.match = FoodMatch(
        item: row.match.item,
        status: MatchStatus.matched,
        food: row.match.food,
        amount: res.amount,
        resolved: resolveAmount(food.basis, res.amount),
      );
      row.include = true;
    });
  }

  Future<void> _lookup(_Row row) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('Look up "${row.match.item.name}"')),
          body: FoodSearchPanel(
            meal: _meal,
            date: widget.date,
            initialQuery: row.match.item.name,
          ),
        ),
      ),
    );
  }

  Future<void> _estimateWithAi() async {
    final unmatched = _rows
        .where((r) => r.match.status == MatchStatus.needsLookup)
        .map((r) => r.match.item.raw)
        .toList();
    final text = unmatched.isEmpty ? _ctrl.text.trim() : unmatched.join(', ');
    setState(() => _aiBusy = true);
    final result = await ref.read(foodTextEstimatorProvider).estimate(text);
    if (!mounted) return;
    setState(() {
      _aiBusy = false;
      switch (result) {
        case FoodEstimateUnavailable(:final reason):
          _aiMessage = reason;
          _estimates = const [];
        case FoodEstimateFailure(:final message):
          _aiMessage = redactSecrets(message);
          _estimates = const [];
        case FoodEstimateSuccess(:final items):
          _aiMessage = items.isEmpty ? 'The AI returned no items.' : null;
          _estimates = [for (final i in items) _EstimateRow(i)];
      }
    });
    if (_estimates.isEmpty) {
      Haptics.warning();
    } else {
      Haptics.success();
    }
  }

  Future<void> _logAll() async {
    final log = ref.read(foodLogRepositoryProvider);
    var count = 0;
    setState(() => _busy = true);
    try {
      for (final r in _rows) {
        if (!r.include || r.match.status != MatchStatus.matched) continue;
        final food = _foodsById[r.match.food!.id];
        if (food == null) continue;
        await log.logFood(
          food,
          amount: r.match.amount!,
          mealType: _meal,
          localDate: widget.date,
        );
        count++;
      }
      for (final e in _estimates) {
        if (!e.confirmed) continue;
        await log.log(
          LogDraft(
            name: e.item.name,
            mealType: _meal,
            nutrients: e.item.nutrients,
            grams: e.item.grams,
            source: FoodSources.aiEstimate,
            verification: Verifications.estimate,
            note: e.item.quantityDescription,
          ),
          localDate: widget.date,
        );
        count++;
      }
    } catch (e) {
      if (mounted) showSnack(context, redactSecrets(e.toString()));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (count > 0) {
      Haptics.success();
      showSnack(context, 'Logged $count item${count == 1 ? '' : 's'}');
      Navigator.of(context).pop(true);
    }
  }

  int get _selectedCount =>
      _rows
          .where((r) => r.include && r.match.status == MatchStatus.matched)
          .length +
      _estimates.where((e) => e.confirmed).length;

  Nutrients get _selectedTotal {
    var n = Nutrients.zero;
    for (final r in _rows) {
      if (r.include && r.match.status == MatchStatus.matched) {
        n = n + r.match.resolved!.nutrients;
      }
    }
    for (final e in _estimates) {
      if (e.confirmed) n = n + e.item.nutrients;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final hasUnmatched = _rows.any(
      (r) => r.match.status == MatchStatus.needsLookup,
    );
    final matchedCount = _rows
        .where((r) => r.match.status == MatchStatus.matched)
        .length;
    final selected = _selectedCount;
    return Scaffold(
      appBar: AppBar(title: const Text('Describe your meal')),
      bottomNavigationBar: _parsed
          ? _CommitBar(
              total: _selectedTotal,
              hasEstimates: _estimates.any((e) => e.confirmed),
              child: HudButton(
                label:
                    'Log $selected item${selected == 1 ? '' : 's'} '
                    'to ${_meal.label}',
                icon: Icons.check_rounded,
                expand: true,
                onPressed: selected == 0 || _busy ? null : _logAll,
              ),
            )
          : null,
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.xxxl,
        ),
        children: [
          AppCard(
            brackets: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('WHAT DID YOU EAT?', style: hud.label(size: 11)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const Key('describe-field'),
                  controller: _ctrl,
                  minLines: 3,
                  maxLines: 6,
                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w400),
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: '150 g paneer, 200 g rice and one banana',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final e in _examples)
                      _ExampleChip(
                        text: e,
                        onTap: () => setState(() {
                          _ctrl.text = e;
                          _ctrl.selection = TextSelection.collapsed(
                            offset: e.length,
                          );
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                MealPicker(
                  value: _meal,
                  onChanged: (m) => setState(() => _meal = m),
                ),
                const SizedBox(height: AppSpacing.md),
                KeyedSubtree(
                  key: const Key('describe-parse'),
                  child: HudButton(
                    label: _parsed ? 'Match again' : 'Match foods',
                    icon: Icons.auto_fix_high_outlined,
                    variant: _parsed
                        ? HudButtonVariant.secondary
                        : HudButtonVariant.primary,
                    expand: true,
                    loading: _busy && !_parsed,
                    onPressed: _busy ? null : _parse,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Matched on this phone against your foods and recents. '
                  'Units: g, kg, ml, l, cup, piece, serving, or words like '
                  '"one", "two".',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
          if (_parsed && _rows.isEmpty)
            const EmptyState(
              compact: true,
              icon: Icons.help_outline,
              title: 'Nothing recognised',
              message: 'Try "200 g rice, 2 rotis".',
            ),
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            HudCaption(
              'Matched on device · $matchedCount of ${_rows.length}',
              trailing: Text('NO AI USED', style: hud.mono(size: 10)),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...staggered([for (final r in _rows) _rowTile(r)]),
          ],
          if (_parsed && hasUnmatched) ...[
            const SizedBox(height: AppSpacing.lg),
            _AiPanel(
              busy: _aiBusy,
              onEstimate: _aiBusy ? null : _estimateWithAi,
            ),
          ],
          if (_aiMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            NoticeBanner(
              message: _aiMessage!,
              icon: Icons.cloud_off_outlined,
              color: AppColors.warning,
            ),
          ],
          if (_estimates.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            const HudCaption(
              'AI estimates · confirm each',
              color: AppColors.warning,
            ),
            const SizedBox(height: AppSpacing.sm),
            ...staggered([
              for (final e in _estimates)
                _EstimateCard(
                  row: e,
                  onChanged: (v) => setState(() => e.confirmed = v),
                ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _rowTile(_Row r) {
    final m = r.match;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    Widget card({
      required Widget leading,
      required String title,
      required String subtitle,
      Widget? trailing,
      Color? accent,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        accent: accent,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    switch (m.status) {
      case MatchStatus.matched:
        final n = m.resolved!.nutrients;
        final food = _foodsById[m.food!.id];
        return card(
          leading: HudToggle(
            value: r.include,
            semanticLabel: 'Include ${m.food!.name}',
            onChanged: (v) => setState(() => r.include = v),
          ),
          title: '${m.food!.name} · ${_amountText(m, food)}',
          subtitle: '"${m.item.raw}"\n${macroSummary(n)}',
          trailing: IconButton(
            tooltip: 'Change amount',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => _chooseAmount(r),
          ),
        );
      case MatchStatus.needsAmount:
        return card(
          accent: AppColors.warning,
          leading: const GlowIcon(
            Icons.straighten,
            color: AppColors.warning,
            framed: true,
            size: 18,
          ),
          title: '${m.food!.name} — choose amount',
          subtitle:
              '"${m.item.raw}": "${m.item.unit.name}" can\'t be converted for '
              'this food (${m.food!.basis.servingLabel} per serving).',
          trailing: TextButton(
            onPressed: () => _chooseAmount(r),
            child: const Text('Amount'),
          ),
        );
      case MatchStatus.needsLookup:
        return card(
          leading: const GlowIcon(Icons.travel_explore, framed: true, size: 18),
          title: 'Needs lookup: ${m.item.name}',
          subtitle: '"${m.item.raw}" isn\'t in your foods yet.',
          trailing: TextButton(
            onPressed: () => _lookup(r),
            child: const Text('Search'),
          ),
        );
    }
  }

  String _amountText(FoodMatch m, Food? food) {
    final r = m.resolved!;
    final unit = food?.basis.baseUnit ?? 'g';
    if (m.amount!.mode == AmountMode.grams) {
      return '${Fmt.oneDp(m.amount!.value)} $unit';
    }
    return amountLabel(r.servings, null);
  }
}

class _AiPanel extends StatelessWidget {
  const _AiPanel({required this.busy, required this.onEstimate});
  final bool busy;
  final VoidCallback? onEstimate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return GlassPanel(
      accent: AppColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_outlined,
                size: 16,
                color: AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('AI estimate (optional)', style: t.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Only the unmatched items are sent. Estimates are approximate '
            'and must be confirmed one by one.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          if (busy) ...[
            const ScanlineLoader(lines: 2, color: AppColors.warning),
            const SizedBox(height: AppSpacing.md),
          ],
          HudButton.secondary(
            label: 'Estimate unmatched items with AI',
            icon: Icons.auto_awesome_outlined,
            expand: true,
            loading: busy,
            onPressed: onEstimate,
          ),
        ],
      ),
    );
  }
}

class _EstimateCard extends StatelessWidget {
  const _EstimateCard({required this.row, required this.onChanged});
  final _EstimateRow row;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final item = row.item;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        accent: AppColors.warning,
        onTap: () => onChanged(!row.confirmed),
        semanticLabel:
            '${item.name}, estimate, ${macroSummary(item.nutrients)}. '
            '${row.confirmed ? 'Confirmed' : 'Not confirmed'}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name, style: t.titleSmall),
                      if (item.quantityDescription != null)
                        Text(
                          item.quantityDescription!,
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                        ),
                    ],
                  ),
                ),
                const EstimateBadge(),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            NutrientPreview(nutrients: item.nutrients, estimate: true),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.confirmed
                        ? 'Confirmed — will be logged as an estimate'
                        : 'Tick to confirm this estimate',
                    style: t.bodySmall?.copyWith(
                      color: row.confirmed ? hud.text : hud.textMuted,
                    ),
                  ),
                ),
                HudToggle(
                  value: row.confirmed,
                  color: AppColors.warning,
                  semanticLabel: 'Confirm ${item.name}',
                  onChanged: onChanged,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Frosted bottom bar with the running total and the commit button.
class _CommitBar extends StatelessWidget {
  const _CommitBar({
    required this.total,
    required this.hasEstimates,
    required this.child,
  });

  final Nutrients total;
  final bool hasEstimates;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hud.glassFillStrong,
        border: Border(
          top: BorderSide(color: hud.accent.withValues(alpha: 0.25)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${Fmt.integer(total.calories)} KCAL · '
                      'P ${Fmt.oneDp(total.protein)} G',
                      style: hud.mono(size: 11.5, color: hud.text),
                    ),
                  ),
                  if (hasEstimates) const EstimateBadge(),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      button: true,
      label: 'Use example: $text',
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.95,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            color: hud.accent.withValues(alpha: 0.06),
            border: Border.all(color: hud.accent.withValues(alpha: 0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.north_west_rounded, size: 13, color: hud.accentInk),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: hud.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
