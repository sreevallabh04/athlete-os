import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/food_lookup_service.dart';
import '../application/providers.dart';
import '../data/indian_food_db.dart';
import '../domain/food_models.dart';
import '../domain/indian_food_db.dart';
import 'ai_food_log_screen.dart';
import 'custom_food_screen.dart';
import 'food_actions.dart';
import 'label_scan_screen.dart';
import 'widgets/cant_find_panel.dart';
import 'widgets/common.dart';
import 'widgets/food_tiles.dart';
import 'widgets/nutrition_hud.dart';

/// Search local foods (instantly, as you type) and Open Food Facts / USDA
/// (on submit only, to respect API rate limits).
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
  List<IndianDish> _indian = const [];
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
    // Indian Food DB: offline, in memory, no rate limit → as you type.
    final db = ref.read(indianFoodDbProvider);
    var index = db.readyIndex;
    if (index == null) {
      try {
        index = await db.index();
      } catch (_) {
        return; // the bundled table could not be read; other sources work
      }
    }
    if (!mounted || seq != _localSeq) return;
    final saved = {
      for (final f in _local)
        if (f.source == FoodSources.indianFoodDb) f.sourceId,
    };
    setState(() {
      _indian = [
        for (final h in index!.search(q, limit: 12))
          if (!saved.contains('row${h.dish.id}')) h.dish,
      ];
    });
  }

  Future<void> _submit() async {
    final q = _ctrl.text.trim();
    if (q.length < 2 || _searching) return;
    FocusScope.of(context).unfocus();
    Haptics.light();
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
    if (r.isEmpty) {
      Haptics.light();
    } else {
      Haptics.selection();
    }
  }

  bool get _offFailed =>
      _remote?.errors.any((e) => e.startsWith('Open Food Facts')) ?? false;

  Future<void> _scanLabel(String q) async {
    final out = await openLabelScan(
      context,
      name: q,
      meal: widget.meal,
      date: widget.date,
    );
    if (out != null && mounted) unawaited(_searchLocal(_ctrl.text));
  }

  Future<void> _enterLabel(String q) async {
    final food = await Navigator.of(context).push<Food>(
      MaterialPageRoute(builder: (_) => CustomFoodScreen(initialName: q)),
    );
    if (food == null || !mounted) return;
    unawaited(_searchLocal(_ctrl.text));
    await logLocalFood(
      context,
      ref,
      food: food,
      meal: widget.meal,
      date: widget.date,
    );
  }

  /// Prefills the AI food log with the meal and the query.
  void _askJarvis(String q) {
    final text = '${widget.meal.label}: $q';
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.push(
        Uri(
          path: AppPaths.aiFoodLog,
          queryParameters: {'q': text, 'date': widget.date},
        ).toString(),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AiFoodLogScreen(initialText: text, initialDate: widget.date),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remote;
    final q = _ctrl.text.trim();
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        MediaQuery.paddingOf(context).bottom + AppSpacing.xxxl,
      ),
      children: [
        TextField(
          key: const Key('food-search-field'),
          controller: _ctrl,
          textInputAction: TextInputAction.search,
          style: t.bodyLarge,
          decoration: InputDecoration(
            hintText: 'Search foods (e.g. paneer, dal, oats)',
            prefixIcon: Icon(Icons.search_rounded, color: hud.accentInk),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _ctrl.clear();
                      _local = const [];
                      _indian = const [];
                      _remote = null;
                    }),
                  ),
          ),
          onChanged: (v) {
            setState(() {});
            unawaited(_searchLocal(v));
          },
          onSubmitted: (_) => _submit(),
        ),
        AnimatedSize(
          duration: AppMotion.reduced(context)
              ? Duration.zero
              : AppMotion.medium,
          curve: AppMotion.emphasizedDecelerate,
          alignment: Alignment.topCenter,
          child: q.length < 2
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: HudButton.secondary(
                    label: 'Search Open Food Facts for "$q"',
                    icon: Icons.travel_explore_rounded,
                    compact: true,
                    expand: true,
                    loading: _searching,
                    onPressed: _searching ? null : _submit,
                  ),
                ),
        ),
        if (widget.header != null) ...[
          const SizedBox(height: AppSpacing.md),
          widget.header!,
        ],
        if (q.isNotEmpty && _local.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          HudCaption(
            'Your foods · ${_local.length}',
            trailing: Text('INSTANT', style: hud.mono(size: 10)),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...staggered([
            for (final f in _local)
              FoodListTile(
                key: ValueKey('local-${f.id}'),
                food: f,
                onTap: () => logLocalFood(
                  context,
                  ref,
                  food: f,
                  meal: widget.meal,
                  date: widget.date,
                ),
              ),
          ]),
        ],
        if (q.length >= 2 && _indian.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          HudCaption(
            'Indian dishes · Indian Food DB · ${_indian.length}',
            color: AppColors.success,
            trailing: Text('OFFLINE', style: hud.mono(size: 10)),
          ),
          const SizedBox(height: 2),
          Text(
            'Home-style recipes, values per 100 g',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...staggered([
            for (final d in _indian)
              CandidateTile(
                key: ValueKey('indian-${d.id}'),
                candidate: d.toCandidate(),
                onTap: () async {
                  final logged = await openCandidate(
                    context,
                    ref,
                    candidate: d.toCandidate(),
                    meal: widget.meal,
                    date: widget.date,
                  );
                  if (logged && mounted) unawaited(_searchLocal(_ctrl.text));
                },
              ),
          ]),
        ],
        if (q.isNotEmpty &&
            _local.isEmpty &&
            _indian.isEmpty &&
            remote == null &&
            !_searching)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.lg),
            child: Text(
              'Not in your foods yet. Press search to look it up online.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ),
        if (_searching) ...[
          const SizedBox(height: AppSpacing.lg),
          const ScanlineLoader(lines: 3),
          const SizedBox(height: AppSpacing.md),
          const ScanlineLoader(lines: 3),
        ],
        if (!_searching && remote != null) ..._remoteResults(remote),
        if (q.length >= 2 && !_searching) ...[
          const SizedBox(height: AppSpacing.lg),
          CantFindPanel(
            query: q,
            prominent:
                remote != null &&
                ((remote.isEmpty && _local.isEmpty && _indian.isEmpty) ||
                    _offFailed),
            onScanLabel: () => _scanLabel(q),
            onEnterLabel: () => _enterLabel(q),
            onAskJarvis: () => _askJarvis(q),
          ),
        ],
        if (q.isEmpty && remote == null)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.lg),
            child: EmptyState(
              compact: true,
              icon: Icons.search,
              eyebrow: 'READY',
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
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
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
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Text(
            'No database results for "$_remoteQuery".',
            style: t.bodyMedium?.copyWith(color: hud.textMuted),
          ),
        ),
      if (r.openFoodFacts.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.lg),
        HudCaption(
          'Open Food Facts · ${r.openFoodFacts.length}',
          color: AppColors.warning,
        ),
        const SizedBox(height: 2),
        Text(
          'Community data — verify against the label',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        ...staggered([
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
        ]),
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.xs),
          child: OffAttribution(),
        ),
      ],
      if (r.usda.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.lg),
        HudCaption('USDA FoodData Central · ${r.usda.length}'),
        const SizedBox(height: 2),
        Text(
          'Generic foods, values per 100 g',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        ...staggered([
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
        ]),
      ],
      if (!r.usdaConfigured)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Text(
            'USDA search is off (no API key configured).',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ),
    ];
  }
}
