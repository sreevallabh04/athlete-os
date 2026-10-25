import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/food_lookup_service.dart';
import '../application/providers.dart';
import '../domain/food_models.dart';
import 'food_actions.dart';
import 'widgets/common.dart';
import 'widgets/food_tiles.dart';

/// Search local foods (as you type) and Open Food Facts / USDA (on submit
/// only, to respect API rate limits).
class FoodSearchPanel extends ConsumerStatefulWidget {
  const FoodSearchPanel({
    super.key,
    required this.meal,
    required this.date,
    this.initialQuery,
    this.header,
    this.autoSubmit = false,
  });

  final MealType meal;
  final String date;
  final String? initialQuery;
  final Widget? header;

  /// Run the remote search immediately for [initialQuery].
  final bool autoSubmit;

  @override
  ConsumerState<FoodSearchPanel> createState() => _FoodSearchPanelState();
}

class _FoodSearchPanelState extends ConsumerState<FoodSearchPanel> {
  late final TextEditingController _ctrl;
  List<Food> _local = const [];
  RemoteSearchResult? _remote;
  String? _remoteQuery;
  bool _searching = false;
  int _localSeq = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery ?? '');
    if (_ctrl.text.isNotEmpty) {
      unawaited(_searchLocal(_ctrl.text));
      if (widget.autoSubmit) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _searchLocal(String q) async {
    final seq = ++_localSeq;
    final r = await ref.read(foodRepositoryProvider).search(q);
    if (mounted && seq == _localSeq) setState(() => _local = r);
  }

  Future<void> _submit() async {
    final q = _ctrl.text.trim();
    if (q.length < 2 || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _remoteQuery = q;
    });
    unawaited(_searchLocal(q));
    final r = await ref.read(foodLookupServiceProvider).searchRemote(q);
    if (!mounted) return;
    setState(() {
      _remote = r;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remote;
    final q = _ctrl.text.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.xxxl,
      ),
      children: [
        TextField(
          key: const Key('food-search-field'),
          controller: _ctrl,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search foods (e.g. paneer, dal, oats)',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _ctrl.clear();
                      _local = const [];
                      _remote = null;
                    }),
                  ),
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) {
            setState(() {});
            unawaited(_searchLocal(v));
          },
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: AppSpacing.xs),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: q.length < 2 || _searching ? null : _submit,
            icon: const Icon(Icons.travel_explore, size: 18),
            label: const Text('Search online databases'),
          ),
        ),
        ?widget.header,
        if (q.isNotEmpty && _local.isNotEmpty) ...[
          const SectionHeader('Your foods'),
          for (final f in _local)
            FoodListTile(
              food: f,
              onTap: () => logLocalFood(
                context,
                ref,
                food: f,
                meal: widget.meal,
                date: widget.date,
              ),
            ),
        ],
        if (_searching) const LoadingState(),
        if (!_searching && remote != null) ..._remoteResults(remote),
        if (q.isEmpty && remote == null)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.xl),
            child: EmptyState(
              compact: true,
              icon: Icons.search,
              title: 'Find a food',
              message:
                  'Your saved foods appear as you type. Press search to look '
                  'up Open Food Facts (and USDA when configured).',
            ),
          ),
      ],
    );
  }

  List<Widget> _remoteResults(RemoteSearchResult r) {
    return [
      for (final e in r.errors) ...[
        const SizedBox(height: AppSpacing.md),
        NoticeBanner(
          message: e,
          icon: Icons.cloud_off_outlined,
          color: AppColors.warning,
        ),
      ],
      if (r.isEmpty && r.errors.isEmpty)
        EmptyState(
          compact: true,
          icon: Icons.search_off,
          title: 'No database results for "$_remoteQuery"',
          message:
              'Indian and regional products are only partly covered. You can '
              'create the food yourself.',
        ),
      if (r.openFoodFacts.isNotEmpty) ...[
        const SectionHeader(
          'Open Food Facts',
          subtitle: 'Community data — verify against the label',
        ),
        for (final c in r.openFoodFacts)
          CandidateTile(
            candidate: c,
            onTap: () => openCandidate(
              context,
              ref,
              candidate: c,
              meal: widget.meal,
              date: widget.date,
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.xs),
          child: OffAttribution(),
        ),
      ],
      if (r.usda.isNotEmpty) ...[
        const SectionHeader(
          'USDA FoodData Central',
          subtitle: 'Generic foods, values per 100 g',
        ),
        for (final c in r.usda)
          CandidateTile(
            candidate: c,
            onTap: () => openCandidate(
              context,
              ref,
              candidate: c,
              meal: widget.meal,
              date: widget.date,
            ),
          ),
      ],
      if (!r.usdaConfigured)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Text(
            'USDA search is off (no API key configured).',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }
}
