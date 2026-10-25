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

class _DescribeMealScreenState extends ConsumerState<DescribeMealScreen> {
  late final _ctrl = TextEditingController(text: widget.initialText ?? '');
  late MealType _meal = widget.meal;
  List<_Row> _rows = const [];
  Map<String, Food> _foodsById = const {};
  bool _parsed = false;
  bool _busy = false;
  String? _aiMessage;
  List<_EstimateRow> _estimates = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
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
    setState(() => _busy = true);
    final result = await ref.read(foodTextEstimatorProvider).estimate(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
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
      showSnack(context, 'Logged $count item${count == 1 ? '' : 's'}');
      Navigator.of(context).pop(true);
    }
  }

  int get _selectedCount =>
      _rows
          .where((r) => r.include && r.match.status == MatchStatus.matched)
          .length +
      _estimates.where((e) => e.confirmed).length;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hasUnmatched = _rows.any(
      (r) => r.match.status == MatchStatus.needsLookup,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Describe your meal')),
      bottomNavigationBar: _parsed
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _selectedCount == 0 || _busy ? null : _logAll,
                    child: Text(
                      'Log $_selectedCount item${_selectedCount == 1 ? '' : 's'} '
                      'to ${_meal.label}',
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          TextField(
            key: const Key('describe-field'),
            controller: _ctrl,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: '150 g paneer, 200 g rice and one banana',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Matched on this phone against your foods and recents. Units: g, '
            'kg, ml, l, cup, piece, serving, or words like "one", "two".',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          MealPicker(value: _meal, onChanged: (m) => setState(() => _meal = m)),
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonalIcon(
            key: const Key('describe-parse'),
            onPressed: _busy ? null : _parse,
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: const Text('Match foods'),
          ),
          if (_busy) const LoadingState(),
          if (_parsed && _rows.isEmpty)
            const EmptyState(
              compact: true,
              icon: Icons.help_outline,
              title: 'Nothing recognised',
              message: 'Try "200 g rice, 2 rotis".',
            ),
          for (final r in _rows) _rowTile(r),
          if (_parsed && hasUnmatched) ...[
            const SectionHeader(
              'AI estimate (optional)',
              subtitle:
                  'Estimates are approximate and must be confirmed one by one.',
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _estimateWithAi,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Estimate unmatched items with AI'),
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
          for (final e in _estimates)
            CheckboxListTile(
              value: e.confirmed,
              onChanged: (v) => setState(() => e.confirmed = v ?? false),
              title: Row(
                children: [
                  Flexible(child: Text(e.item.name)),
                  const SizedBox(width: AppSpacing.xs),
                  const EstimateBadge(),
                ],
              ),
              subtitle: Text(
                '${e.item.quantityDescription ?? ''}\n'
                '${macroSummary(e.item.nutrients)}\n'
                'Tick to confirm this estimate',
              ),
              isThreeLine: true,
            ),
        ],
      ),
    );
  }

  Widget _rowTile(_Row r) {
    final m = r.match;
    final scheme = Theme.of(context).colorScheme;
    switch (m.status) {
      case MatchStatus.matched:
        final n = m.resolved!.nutrients;
        final food = _foodsById[m.food!.id];
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: r.include,
          onChanged: (v) => setState(() => r.include = v ?? false),
          title: Text('${m.food!.name} · ${_amountText(m, food)}'),
          subtitle: Text(
            '"${m.item.raw}"\n${macroSummary(n)}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          isThreeLine: true,
          secondary: IconButton(
            tooltip: 'Change amount',
            icon: const Icon(Icons.tune),
            onPressed: () => _chooseAmount(r),
          ),
        );
      case MatchStatus.needsAmount:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.straighten, color: AppColors.warning),
          title: Text('${m.food!.name} — choose amount'),
          subtitle: Text(
            '"${m.item.raw}": "${m.item.unit.name}" can\'t be converted for '
            'this food (${m.food!.basis.servingLabel} per serving).',
          ),
          trailing: TextButton(
            onPressed: () => _chooseAmount(r),
            child: const Text('Amount'),
          ),
        );
      case MatchStatus.needsLookup:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.travel_explore, color: AppColors.info),
          title: Text('Needs lookup: ${m.item.name}'),
          subtitle: Text('"${m.item.raw}" isn\'t in your foods yet.'),
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
