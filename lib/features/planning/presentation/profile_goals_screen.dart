import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/profile_repository.dart';
import '../application/planning_providers.dart';
import '../data/metrics_queries.dart';
import '../data/planning_repository.dart';
import '../data/profile_mapping.dart';
import '../domain/profile_diff.dart';
import 'widgets/ui_helpers.dart';

final _latestWeightProvider = StreamProvider((ref) {
  final db = ref.watch(databaseProvider);
  final q = ref.watch(metricsQueriesProvider);
  return watchTables(db, {db.healthSamples}, q.latestWeight);
});

final _goalHistoryProvider = StreamProvider<List<GoalHistoryData>>(
  (ref) => ref.watch(planningRepositoryProvider).watchGoalHistory(),
);

class ProfileGoalsScreen extends ConsumerWidget {
  const ProfileGoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    return profile.when(
      loading: () =>
          const AppPage(title: 'Profile & goals', children: [LoadingState()]),
      error: (e, _) => AppPage(
        title: 'Profile & goals',
        children: [
          ErrorState(
            message: 'Could not load your profile.',
            onRetry: () => ref.invalidate(profileProvider),
          ),
        ],
      ),
      data: (p) => _ProfileForm(profile: p),
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({required this.profile});
  final UserProfile profile;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  final _form = GlobalKey<FormState>();
  late ProfileDraft _base;
  late final Map<String, TextEditingController> _c;
  late String _diet;
  late String _style;
  late int _wake;
  late int _sleep;
  late List<String> _restrictions;
  late List<String> _disliked;
  bool _saving = false;

  static String _num(num? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.round().toString() : v.toString();
  }

  @override
  void initState() {
    super.initState();
    _load(widget.profile);
  }

  void _load(UserProfile p) {
    _base = draftFromProfile(p);
    final d = _base;
    _c = {
      'name': TextEditingController(text: d.displayName ?? ''),
      'height': TextEditingController(text: _num(d.heightCm)),
      'targetWeight': TextEditingController(text: _num(d.targetWeightKg)),
      'kcal': TextEditingController(text: '${d.calorieTarget}'),
      'protein': TextEditingController(text: _num(d.proteinTargetG)),
      'carbs': TextEditingController(text: _num(d.carbsTargetG)),
      'fat': TextEditingController(text: _num(d.fatTargetG)),
      'fiber': TextEditingController(text: _num(d.fiberTargetG)),
      'steps': TextEditingController(text: '${d.stepGoal}'),
      'water': TextEditingController(text: '${d.waterGoalMl}'),
      'availability': TextEditingController(text: d.trainingAvailability ?? ''),
      'runKm': TextEditingController(text: _num(d.runGoalDistanceM / 1000)),
      'runTime': TextEditingController(text: formatSeconds(d.runGoalTimeS)),
      'goals': TextEditingController(text: d.fitnessGoals ?? ''),
    };
    _diet = d.dietType;
    _style = d.coachingStyle;
    _wake = d.wakeMinutes;
    _sleep = d.sleepMinutes;
    _restrictions = [...d.restrictions];
    _disliked = [...d.dislikedFoods];
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _d(String k) => double.tryParse(_c[k]!.text.trim());
  int? _i(String k) => int.tryParse(_c[k]!.text.trim());

  ProfileDraft _draft() => ProfileDraft(
    displayName: _c['name']!.text.trim(),
    heightCm: _d('height'),
    targetWeightKg: _d('targetWeight'),
    dietType: _diet,
    restrictions: _restrictions,
    dislikedFoods: _disliked,
    calorieTarget: _i('kcal') ?? _base.calorieTarget,
    proteinTargetG: _d('protein') ?? _base.proteinTargetG,
    carbsTargetG: _d('carbs') ?? _base.carbsTargetG,
    fatTargetG: _d('fat') ?? _base.fatTargetG,
    fiberTargetG: _d('fiber'),
    stepGoal: _i('steps') ?? _base.stepGoal,
    waterGoalMl: _i('water') ?? _base.waterGoalMl,
    wakeMinutes: _wake,
    sleepMinutes: _sleep,
    coachingStyle: _style,
    trainingAvailability: _c['availability']!.text.trim(),
    runGoalDistanceM: ((_d('runKm') ?? _base.runGoalDistanceM / 1000) * 1000)
        .round(),
    runGoalTimeS: parseDuration(_c['runTime']!.text) ?? _base.runGoalTimeS,
    fitnessGoals: _c['goals']!.text.trim(),
  );

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final draft = _draft();
    final changes = diffProfile(_base, draft);
    if (changes.isEmpty) {
      showSnack(context, 'No changes to save');
      return;
    }
    if (changes.any((c) => c.isTarget)) {
      final caution = calorieCaution(_base.calorieTarget, draft.calorieTarget);
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _ConfirmChangesDialog(
          changes: changes,
          caution: _base.calorieTarget != draft.calorieTarget
              ? caution
              : CalorieCaution.none,
        ),
      );
      if (ok != true) return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .update(companionFromDraft(draft), changedBy: 'user');
      _base = draft;
      if (mounted) showSnack(context, 'Profile saved');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validNum(
    String? v, {
    required double min,
    required double max,
    bool optional = false,
  }) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return optional ? null : 'Required';
    final n = double.tryParse(s);
    if (n == null) return 'Enter a number';
    if (n < min || n > max) return 'Between ${_num(min)} and ${_num(max)}';
    return null;
  }

  Widget _numField(
    String key,
    String label, {
    String? suffix,
    required double min,
    required double max,
    bool optional = false,
    bool decimal = true,
    double? step,
  }) => TextFormField(
    controller: _c[key],
    keyboardType: TextInputType.numberWithOptions(decimal: decimal),
    inputFormatters: [
      FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.]' : r'[0-9]')),
    ],
    // Same input text as every other form (Custom food, Habit editor…).
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      suffixIcon: step == null
          ? null
          : _Nudge(
              label: label,
              onStep: (dir) {
                final c = _c[key]!;
                final now = double.tryParse(c.text.trim()) ?? min;
                final next = (now + step * dir).clamp(min, max);
                c.text = _num(next.toDouble());
                Haptics.selection();
                setState(() {});
              },
            ),
    ),
    validator: (v) => _validNum(v, min: min, max: max, optional: optional),
  );

  Future<void> _pickTime(bool wake) async {
    final m = wake ? _wake : _sleep;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      helpText: wake ? 'Wake time' : 'Sleep time',
    );
    if (picked == null) return;
    setState(() {
      final v = picked.hour * 60 + picked.minute;
      if (wake) {
        _wake = v;
      } else {
        _sleep = v;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget row(List<Widget> children) => LayoutBuilder(
      builder: (context, c) => c.maxWidth < 420
          ? Column(children: spaced(children))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.md),
                  Expanded(child: children[i]),
                ],
              ],
            ),
    );

    return AppPage(
      title: 'Profile & goals',
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NoticeBanner(
                icon: Icons.info_outline,
                message:
                    'Targets are editable examples, not medical advice. '
                    'Changes are confirmed and recorded in goal history.',
              ),
              const SectionHeader('About you'),
              AppCard(
                child: Column(
                  children: spaced([
                    TextFormField(
                      controller: _c['name'],
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                      ),
                    ),
                    row([
                      _numField(
                        'height',
                        'Height',
                        suffix: 'cm',
                        min: 100,
                        max: 250,
                        optional: true,
                      ),
                      _numField(
                        'targetWeight',
                        'Target weight',
                        suffix: 'kg',
                        min: 30,
                        max: 250,
                        optional: true,
                      ),
                    ]),
                    const _CurrentWeight(),
                  ]),
                ),
              ),
              const SectionHeader('Diet'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced([
                    DropdownButtonFormField<String>(
                      initialValue: _diet,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Diet type'),
                      items: const [
                        DropdownMenuItem(
                          value: 'eggetarian',
                          child: Text('Eggetarian (vegetarian + eggs)'),
                        ),
                        DropdownMenuItem(
                          value: 'vegetarian',
                          child: Text('Vegetarian'),
                        ),
                        DropdownMenuItem(value: 'vegan', child: Text('Vegan')),
                        DropdownMenuItem(
                          value: 'pescatarian',
                          child: Text('Pescatarian'),
                        ),
                        DropdownMenuItem(
                          value: 'omnivore',
                          child: Text('Omnivore'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _diet = v ?? _diet),
                    ),
                    _ChipEditor(
                      label: 'Dietary restrictions / allergies',
                      hint: 'e.g. lactose, peanuts',
                      values: _restrictions,
                      onChanged: (v) => setState(() => _restrictions = v),
                    ),
                    _ChipEditor(
                      label: 'Disliked foods',
                      hint: 'e.g. mushrooms',
                      values: _disliked,
                      onChanged: (v) => setState(() => _disliked = v),
                    ),
                  ]),
                ),
              ),
              const SectionHeader(
                'Daily targets',
                subtitle: 'Examples, not medical advice',
              ),
              AppCard(
                child: Column(
                  children: spaced([
                    row([
                      _numField(
                        'kcal',
                        'Calories',
                        step: 50,
                        suffix: 'kcal',
                        min: 800,
                        max: 6000,
                        decimal: false,
                      ),
                      _numField(
                        'protein',
                        'Protein',
                        step: 5,
                        suffix: 'g',
                        min: 0,
                        max: 400,
                      ),
                    ]),
                    row([
                      _numField(
                        'carbs',
                        'Carbs',
                        step: 5,
                        suffix: 'g',
                        min: 0,
                        max: 900,
                      ),
                      _numField(
                        'fat',
                        'Fat',
                        suffix: 'g',
                        min: 0,
                        max: 300,
                        step: 5,
                      ),
                    ]),
                    row([
                      _numField(
                        'fiber',
                        'Fiber',
                        suffix: 'g',
                        min: 0,
                        max: 120,
                        optional: true,
                      ),
                      _numField(
                        'steps',
                        'Step goal',
                        step: 500,
                        min: 0,
                        max: 60000,
                        decimal: false,
                      ),
                    ]),
                    _numField(
                      'water',
                      'Water goal',
                      step: 250,
                      suffix: 'ml',
                      min: 0,
                      max: 8000,
                      decimal: false,
                    ),
                  ]),
                ),
              ),
              const SectionHeader('Schedule & training'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: spaced([
                    row([
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: () => _pickTime(true),
                        icon: const Icon(Icons.wb_twilight),
                        label: Text('Wake ${formatMinutes(_wake)}'),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: () => _pickTime(false),
                        icon: const Icon(Icons.bedtime_outlined),
                        label: Text('Sleep ${formatMinutes(_sleep)}'),
                      ),
                    ]),
                    TextFormField(
                      controller: _c['availability'],
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Training availability',
                        hintText: 'e.g. Mon–Sat mornings, 75 min',
                      ),
                    ),
                    row([
                      _numField(
                        'runKm',
                        'Run goal distance',
                        suffix: 'km',
                        min: 0.4,
                        max: 100,
                      ),
                      TextFormField(
                        controller: _c['runTime'],
                        decoration: const InputDecoration(
                          labelText: 'Run goal time',
                          hintText: 'mm:ss or h:mm:ss',
                        ),
                        validator: (v) =>
                            parseDuration(v ?? '') == null ||
                                parseDuration(v!)! <= 0
                            ? 'Use mm:ss'
                            : null,
                      ),
                    ]),
                    TextFormField(
                      controller: _c['goals'],
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Fitness goals',
                        hintText: 'e.g. Step on stage conditioned and healthy; 5K under 30:00',
                      ),
                    ),
                    Text('COACHING STYLE', style: context.hud.label(size: 11)),
                    SegmentedHud<String>(
                      segments: const [
                        HudSegment(value: 'direct', label: 'Direct'),
                        HudSegment(value: 'encouraging', label: 'Warm'),
                        HudSegment(value: 'analytical', label: 'Analytical'),
                      ],
                      value: _style,
                      onChanged: (v) => setState(() => _style = v),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: _saving ? null : _save,
                child: const Text('Save changes'),
              ),
              const SectionHeader(
                'Injuries & restrictions',
                subtitle: 'Respected in every session',
              ),
              const _RestrictionsCard(),
              const SectionHeader('Goal history'),
              const _GoalHistoryCard(),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConfirmChangesDialog extends StatelessWidget {
  const _ConfirmChangesDialog({required this.changes, required this.caution});
  final List<FieldChange> changes;
  final CalorieCaution caution;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AlertDialog(
      icon: const GlowIcon(Icons.compare_arrows, framed: true, size: 20),
      title: const Text('Confirm target changes'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '${changes.length} CHANGE${changes.length == 1 ? '' : 'S'} · '
              'LOGGED TO GOAL HISTORY',
              style: hud.mono(size: 10, color: hud.accentInk),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final c in changes)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  color: (c.isTarget ? hud.accent : hud.text).withValues(
                    alpha: c.isTarget ? 0.08 : 0.03,
                  ),
                  border: Border.all(
                    color: (c.isTarget ? hud.accent : hud.hairline).withValues(
                      alpha: c.isTarget ? 0.35 : 0.12,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        c.label,
                        style: t.bodyMedium?.copyWith(
                          fontWeight: c.isTarget ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        '${c.oldText} → ${c.newText}',
                        textAlign: TextAlign.right,
                        style: hud.mono(
                          size: 12.5,
                          color: c.isTarget ? hud.accentInk : hud.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (caution != CalorieCaution.none) ...[
              const SizedBox(height: AppSpacing.md),
              NoticeBanner(
                icon: Icons.health_and_safety_outlined,
                color: AppColors.warning,
                message: calorieCautionMessage(caution),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            const Hint(
              'Example targets, not medical advice. Every change is logged in goal history.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save changes'),
        ),
      ],
    );
  }
}

class _ChipEditor extends StatefulWidget {
  const _ChipEditor({
    required this.label,
    required this.hint,
    required this.values,
    required this.onChanged,
  });
  final String label;
  final String hint;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_ChipEditor> createState() => _ChipEditorState();
}

class _ChipEditorState extends State<_ChipEditor> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    final v = _c.text.trim();
    if (v.isEmpty) return;
    if (!widget.values.map((e) => e.toLowerCase()).contains(v.toLowerCase())) {
      widget.onChanged([...widget.values, v]);
    }
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _c,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            suffixIcon: IconButton(
              tooltip: 'Add',
              icon: const Icon(Icons.add),
              onPressed: _add,
            ),
          ),
          onSubmitted: (_) => _add(),
        ),
        if (widget.values.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final v in widget.values)
                InputChip(
                  label: Text(v),
                  onDeleted: () => widget.onChanged(
                    widget.values.where((x) => x != v).toList(),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _CurrentWeight extends ConsumerWidget {
  const _CurrentWeight();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(_latestWeightProvider).value;
    final now = ref.watch(clockProvider).now();
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Current body weight', style: t.labelLarge),
              const SizedBox(height: 2),
              if (w == null)
                const Hint('No weight recorded yet.')
              else ...[
                Text('${w.kg.toStringAsFixed(1)} kg', style: t.titleMedium),
                const SizedBox(height: 2),
                SourceBadge(
                  origin: DataOrigin.fromKey(w.origin),
                  asOf: w.at,
                  now: now,
                  staleAfter: const Duration(days: 7),
                ),
              ],
            ],
          ),
        ),
        TextButton(
          onPressed: () => context.push(AppPaths.healthOverview),
          child: Text(w == null ? 'Add weight' : 'Update'),
        ),
      ],
    );
  }
}

class _RestrictionsCard extends ConsumerWidget {
  const _RestrictionsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(restrictionsProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          list.when(
            loading: () => const LoadingState(),
            error: (e, _) => const Hint('Could not load restrictions.'),
            data: (items) => items.isEmpty
                ? const Hint('No injuries or restrictions recorded.')
                : Column(
                    children: [
                      for (final r in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            r.clinicianImposed
                                ? Icons.medical_services_outlined
                                : Icons.healing_outlined,
                            color: r.clinicianImposed
                                ? AppColors.danger
                                : AppColors.warning,
                          ),
                          title: Text(r.description),
                          subtitle: Text(
                            [
                              ?r.bodyPart,
                              ?r.restriction,
                              if (r.clinicianImposed) 'Set by a clinician',
                              if (r.startDate != null || r.endDate != null)
                                '${r.startDate ?? '…'} → ${r.endDate ?? 'ongoing'}',
                            ].join(' · '),
                          ),
                          onTap: () => _edit(context, ref, r),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await confirm(
                                context,
                                title: 'Remove restriction?',
                                message:
                                    'The coach will no longer take "${r.description}" into account.',
                                confirmLabel: 'Remove',
                                destructive: true,
                              );
                              if (ok) {
                                await ref
                                    .read(planningRepositoryProvider)
                                    .deleteRestriction(r.id);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add injury or restriction'),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    HealthRestriction? r,
  ]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _RestrictionDialog(existing: r),
    );
  }
}

class _RestrictionDialog extends ConsumerStatefulWidget {
  const _RestrictionDialog({this.existing});
  final HealthRestriction? existing;

  @override
  ConsumerState<_RestrictionDialog> createState() => _RestrictionDialogState();
}

class _RestrictionDialogState extends ConsumerState<_RestrictionDialog> {
  late final _desc = TextEditingController(text: widget.existing?.description);
  late final _part = TextEditingController(text: widget.existing?.bodyPart);
  late final _rule = TextEditingController(text: widget.existing?.restriction);
  late bool _clinician = widget.existing?.clinicianImposed ?? false;
  late String? _start = widget.existing?.startDate;
  late String? _end = widget.existing?.endDate;

  @override
  void dispose() {
    _desc.dispose();
    _part.dispose();
    _rule.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add restriction' : 'Edit restriction',
      ),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: spaced([
            TextField(
              controller: _desc,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'e.g. Left shoulder impingement',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _part,
              decoration: const InputDecoration(
                labelText: 'Body part (optional)',
              ),
            ),
            TextField(
              controller: _rule,
              decoration: const InputDecoration(
                labelText: 'What to avoid (optional)',
                hintText: 'e.g. No overhead pressing',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _clinician,
              title: const Text('Set by a clinician'),
              subtitle: const Text('The coach treats these as hard limits.'),
              onChanged: (v) => setState(() => _clinician = v),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await pickDateKey(context, initial: _start);
                      if (d != null) setState(() => _start = d);
                    },
                    child: Text(_start == null ? 'Start date' : 'From $_start'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await pickDateKey(context, initial: _end);
                      if (d != null) setState(() => _end = d);
                    },
                    child: Text(_end == null ? 'End date' : 'Until $_end'),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _desc.text.trim().isEmpty
              ? null
              : () async {
                  await ref
                      .read(planningRepositoryProvider)
                      .saveRestriction(
                        id: widget.existing?.id,
                        description: _desc.text,
                        bodyPart: _part.text,
                        restriction: _rule.text,
                        clinicianImposed: _clinician,
                        startDate: _start,
                        endDate: _end,
                      );
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _GoalHistoryCard extends ConsumerWidget {
  const _GoalHistoryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_goalHistoryProvider);
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: history.when(
        loading: () => const LoadingState(),
        error: (e, _) => const Hint('Could not load goal history.'),
        data: (items) => items.isEmpty
            ? const Hint('No changes yet.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _metricLabel(g.metric),
                                  style: t.bodyMedium,
                                ),
                                Text(
                                  '${formatDateKey(LocalDates.key(g.changedAt))} · '
                                  '${g.changedBy == 'ai_approved' ? 'AI suggestion you approved' : 'You'}',
                                  style: t.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: Text(
                              '${g.oldValue ?? '—'} → ${g.newValue.isEmpty ? '—' : g.newValue}',
                              textAlign: TextAlign.right,
                              style: t.labelLarge,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  static String _metricLabel(String key) => switch (key) {
    'restrictionsJson' => 'Dietary restrictions',
    'dislikedFoodsJson' => 'Disliked foods',
    'wakeMinutes' => 'Wake time (min after midnight)',
    'sleepMinutes' => 'Sleep time (min after midnight)',
    'runGoalTimeS' => 'Run goal time (s)',
    _ => const ProfileDraft().fields[key]?.label ?? key,
  };
}

/// Inline −/+ nudges inside a numeric field.
class _Nudge extends StatelessWidget {
  const _Nudge({required this.label, required this.onStep});
  final String label;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    Widget b(int dir, IconData icon, String tip) => IconButton(
      tooltip: '$tip $label',
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18, color: hud.accentInk),
      onPressed: () => onStep(dir),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [b(-1, Icons.remove, 'Decrease'), b(1, Icons.add, 'Increase')],
    );
  }
}
