import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/train_providers.dart';
import '../data/csv_import_service.dart';
import '../data/workout_repository.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';
import '../domain/workout_draft.dart';
import 'widgets/hud_kit.dart';

class _SetRow {
  _SetRow({String weight = '', String reps = ''})
    : weight = TextEditingController(text: weight),
      reps = TextEditingController(text: reps);
  final TextEditingController weight;
  final TextEditingController reps;
  final burst = CelebrationController();
  bool warmup = false;
  bool done = false;

  double? get kg => double.tryParse(weight.text.replaceAll(',', '.'));
  int? get repCount => int.tryParse(reps.text);

  void dispose() {
    weight.dispose();
    reps.dispose();
    burst.dispose();
  }
}

class _ExerciseRow {
  _ExerciseRow({String name = '', int sets = 1, this.plan, this.rest = 90})
    : name = TextEditingController(text: name),
      sets = [for (var i = 0; i < (sets < 1 ? 1 : sets); i++) _SetRow()];
  final TextEditingController name;
  final List<_SetRow> sets;

  /// Planned prescription, e.g. "4 × 6–10 @ RIR 2".
  final String? plan;

  /// Rest between sets in seconds (from the program; 90 s otherwise).
  final int rest;

  void dispose() {
    name.dispose();
    for (final s in sets) {
      s.dispose();
    }
  }
}

/// Manual strength logging (source `manual`), built for the gym floor:
/// big targets, last-session hints, live set/volume counters, a reactor-ring
/// rest timer that starts when you tick a set (haptic at zero) and a gold
/// PR flash when a set beats your best estimated 1RM.
class LogWorkoutScreen extends ConsumerStatefulWidget {
  const LogWorkoutScreen({super.key, this.initial, this.restSeconds});

  /// Optional pre-filled draft (e.g. a planned program session): title,
  /// notes, exercise names and empty set rows.
  final WorkoutDraft? initial;

  /// Rest per exercise of [initial] (same order), from the program.
  final List<int>? restSeconds;

  static Future<void> open(
    BuildContext context, {
    WorkoutDraft? initial,
    List<int>? restSeconds,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          LogWorkoutScreen(initial: initial, restSeconds: restSeconds),
    ),
  );

  @override
  ConsumerState<LogWorkoutScreen> createState() => _LogWorkoutScreenState();
}

class _LogWorkoutScreenState extends ConsumerState<LogWorkoutScreen>
    with TickerProviderStateMixin {
  final _title = TextEditingController(text: 'Workout');
  final _notes = TextEditingController();
  final _exercises = <_ExerciseRow>[_ExerciseRow()];
  late DateTime _start;
  int _durationMin = 60;
  bool _saving = false;

  // Rest timer.
  late final AnimationController _rest = AnimationController(vsync: this)
    ..addStatusListener(_onRestStatus);
  Duration _restTotal = const Duration(seconds: 90);
  bool _restVisible = false;
  bool _restMounted = false;
  bool _restDone = false;
  String? _restFor;

  static const _durations = [30, 45, 60, 75, 90, 120];

  @override
  void initState() {
    super.initState();
    _start = ref.read(clockProvider).now();
    final init = widget.initial;
    if (init != null && init.exercises.isNotEmpty) {
      _title.text = init.title;
      _notes.text = init.notes ?? '';
      final rest = widget.restSeconds;
      _exercises
        ..clear()
        ..addAll([
          for (var i = 0; i < init.exercises.length; i++)
            _ExerciseRow(
              name: init.exercises[i].name,
              sets: init.exercises[i].sets.length,
              plan: init.exercises[i].notes,
              rest: rest != null && i < rest.length && rest[i] > 0
                  ? rest[i]
                  : 90,
            ),
        ]);
      if (init.endAt != null) {
        final m = init.endAt!.difference(init.startAt).inMinutes;
        _durationMin = _durations.firstWhere((d) => d >= m, orElse: () => 120);
      }
    }
  }

  @override
  void dispose() {
    _rest.dispose();
    _title.dispose();
    _notes.dispose();
    for (final e in _exercises) {
      e.dispose();
    }
    super.dispose();
  }

  // ── Rest timer ───────────────────────────────────────────────────────────

  void _startRest(int seconds, String label) {
    _restTotal = Duration(seconds: seconds);
    _rest.duration = _restTotal;
    setState(() {
      _restVisible = true;
      _restMounted = true;
      _restDone = false;
      _restFor = label;
    });
    _rest.forward(from: 0);
  }

  void _adjustRest(int deltaS) {
    Haptics.selection();
    final elapsedMs = (_restTotal.inMilliseconds * _rest.value).round();
    final totalMs = math.max(
      elapsedMs + 5000,
      _restTotal.inMilliseconds + deltaS * 1000,
    );
    _restTotal = Duration(milliseconds: totalMs);
    _rest.duration = _restTotal;
    _rest.forward(from: elapsedMs / totalMs);
    setState(() {});
  }

  void _stopRest() {
    _rest.stop();
    setState(() {
      _restVisible = false;
      _restDone = false;
    });
  }

  void _onRestStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || !mounted || !_restVisible) return;
    Haptics.goalReached();
    setState(() => _restDone = true);
  }

  // ── Data ─────────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2015),
      lastDate: ref.read(clockProvider).now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    setState(() {
      _start = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _start.hour,
        t?.minute ?? _start.minute,
      );
    });
  }

  WorkoutDraft? _draft() {
    final exercises = <ExerciseDraft>[];
    for (final e in _exercises) {
      final name = e.name.text.trim();
      if (name.isEmpty) continue;
      final sets = <SetDraft>[];
      for (final s in e.sets) {
        final w = s.kg;
        final r = s.repCount;
        if (w == null && r == null) continue;
        sets.add(
          SetDraft(
            type: s.warmup ? SetTypes.warmup : SetTypes.normal,
            weightKg: w,
            reps: r,
          ),
        );
      }
      exercises.add(ExerciseDraft(name: name, sets: sets));
    }
    if (exercises.isEmpty) return null;
    return WorkoutDraft(
      title: _title.text.trim().isEmpty ? 'Workout' : _title.text.trim(),
      startAt: _start,
      endAt: _start.add(Duration(minutes: _durationMin)),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      exercises: exercises,
    );
  }

  Future<void> _save() async {
    final draft = _draft();
    if (draft == null) {
      Haptics.warning();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one named exercise.')),
      );
      return;
    }
    setState(() => _saving = true);
    await ref.read(workoutRepositoryProvider).saveManual(draft);
    if (!mounted) return;
    Haptics.success();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Workout saved')));
  }

  void _toggleDone(_ExerciseRow e, _SetRow s, ExerciseHistory? h) {
    final willBeDone = !s.done;
    setState(() => s.done = willBeDone);
    if (!willBeDone) {
      Haptics.light();
      return;
    }
    final e1 = s.warmup ? null : epley1Rm(s.kg, s.repCount);
    final best = h?.bestE1Rm;
    if (e1 != null && best != null && e1 > best + 0.05) {
      s.burst.fire();
      Haptics.goalReached();
    } else {
      Haptics.medium();
    }
    final name = e.name.text.trim();
    _startRest(e.rest, name.isEmpty ? 'Next set' : name);
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final logs = ref.watch(workoutLogsProvider).value ?? const <WorkoutLog>[];
    final histories = {for (final h in exerciseHistories(logs)) h.key: h};
    final working = [
      for (final e in _exercises)
        for (final s in e.sets)
          if (!s.warmup) s,
    ];
    final doneSets = working.where((s) => s.done).length;
    final volume = working.fold<double>(
      0,
      (a, s) => a + (s.done ? (s.kg ?? 0) * (s.repCount ?? 0) : 0),
    );
    final bottom = MediaQuery.paddingOf(context).bottom;

    final page = AppPage(
      title: 'Log workout',
      eyebrow:
          'MANUAL · ${Fmt.weekdayDayMonth(_start).toUpperCase()} · '
          '${Fmt.time(_start).toUpperCase()}',
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: AppSpacing.md),
              PressableScale(
                onTap: _pickDate,
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Icon(Icons.event, size: 18, color: hud.accent),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          '${Fmt.weekdayDayMonth(_start)} · '
                          '${Fmt.time(_start)}',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Icon(Icons.edit_outlined, size: 14, color: hud.textMuted),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final m in _durations)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.xs),
                        child: HudChip(
                          label: '$m min',
                          selected: m == _durationMin,
                          onTap: () => setState(() => _durationMin = m),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _LiveStrip(
          doneSets: doneSets,
          totalSets: working.length,
          volume: volume,
        ),
        for (var i = 0; i < _exercises.length; i++) ...[
          const SizedBox(height: AppSpacing.md),
          _ExerciseEditor(
            key: ObjectKey(_exercises[i]),
            index: i,
            row: _exercises[i],
            history: histories[exerciseKey(_exercises[i].name.text)],
            canRemove: _exercises.length > 1,
            onRemove: () => setState(() => _exercises.removeAt(i).dispose()),
            onChanged: () => setState(() {}),
            onToggleDone: (s) => _toggleDone(
              _exercises[i],
              s,
              histories[exerciseKey(_exercises[i].name.text)],
            ),
            onAddSet: () => setState(() {
              final last = _exercises[i].sets.last;
              _exercises[i].sets.add(
                _SetRow(weight: last.weight.text, reps: last.reps.text),
              );
            }),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        HudButton.secondary(
          label: 'Add exercise',
          icon: Icons.add,
          expand: true,
          onPressed: () => setState(() => _exercises.add(_ExerciseRow())),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _notes,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
        ),
        const SizedBox(height: AppSpacing.xl),
        HudButton(
          label: 'Finish & save',
          icon: Icons.check,
          expand: true,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
        AnimatedSize(
          duration: AppMotion.medium,
          child: SizedBox(height: _restVisible ? 110 : 0),
        ),
      ],
    );

    return Stack(
      children: [
        page,
        if (_restMounted)
          Positioned(
            left: AppSpacing.gutter,
            right: AppSpacing.gutter,
            bottom: bottom + AppSpacing.md,
            child: IgnorePointer(
              ignoring: !_restVisible,
              child: AnimatedSlide(
                onEnd: () {
                  if (!_restVisible && mounted) {
                    setState(() => _restMounted = false);
                  }
                },
                offset: _restVisible ? Offset.zero : const Offset(0, 1.5),
                duration: AppMotion.entrance,
                curve: _restVisible
                    ? SpringCurve(AppMotion.bouncy)
                    : AppMotion.emphasizedAccelerate,
                child: AnimatedOpacity(
                  opacity: _restVisible ? 1 : 0,
                  duration: AppMotion.medium,
                  child: _RestTimerPanel(
                    controller: _rest,
                    total: _restTotal,
                    done: _restDone,
                    label: _restFor,
                    onMinus: () => _adjustRest(-15),
                    onPlus: () => _adjustRest(15),
                    onSkip: _stopRest,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Live counters while logging.
class _LiveStrip extends StatelessWidget {
  const _LiveStrip({
    required this.doneSets,
    required this.totalSets,
    required this.volume,
  });
  final int doneSets;
  final int totalSets;
  final double volume;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final frac = totalSets == 0 ? 0.0 : doneSets / totalSets;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Sets done',
                  value: '$doneSets/$totalSets',
                  size: 24,
                ),
              ),
              Expanded(
                child: HudReadout(
                  label: 'Volume',
                  value: Fmt.integer(volume),
                  unit: 'kg',
                  size: 24,
                  color: AppColors.strength,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 4,
            child: HudTrack(fraction: frac, color: hud.accent),
          ),
        ],
      ),
    );
  }
}

class _ExerciseEditor extends StatelessWidget {
  const _ExerciseEditor({
    super.key,
    required this.index,
    required this.row,
    required this.history,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
    required this.onToggleDone,
    required this.onAddSet,
  });

  final int index;
  final _ExerciseRow row;
  final ExerciseHistory? history;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  final ValueChanged<_SetRow> onToggleDone;
  final VoidCallback onAddSet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final last = history?.sessions.lastOrNull?.best?.set;
    final best = history?.bestE1Rm;
    final hint = [
      if (row.plan != null) row.plan!,
      if (last != null && last.weightKg != null)
        'last ${Fmt.oneDp(last.weightKg!)} kg × ${last.reps ?? '–'}',
      if (best != null) 'best e1RM ${Fmt.oneDp(best)}',
    ].join('  ·  ');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HudBadge(
                text: (index + 1).toString().padLeft(2, '0'),
                color: AppColors.strength,
                size: 32,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  controller: row.name,
                  onChanged: (_) => onChanged(),
                  decoration: InputDecoration(
                    labelText: 'Exercise ${index + 1}',
                    hintText: 'e.g. Bench Press (Barbell)',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                  style: t.titleSmall,
                  textCapitalization: TextCapitalization.words,
                ),
              ),
              IconButton(
                tooltip: 'Remove exercise',
                onPressed: canRemove ? onRemove : null,
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: 40,
                right: AppSpacing.md,
                bottom: AppSpacing.sm,
              ),
              child: Text(hint, style: hud.mono(size: 10.5)),
            ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text('SET', style: hud.label(size: 10.5)),
                ),
                Expanded(child: Text('KG', style: hud.label(size: 10.5))),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text('REPS', style: hud.label(size: 10.5))),
                const SizedBox(width: 52),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (var j = 0; j < row.sets.length; j++)
            _SetEditor(
              key: ObjectKey(row.sets[j]),
              number: j + 1,
              set: row.sets[j],
              best: best,
              lastHint: last,
              onChanged: onChanged,
              onToggleDone: () => onToggleDone(row.sets[j]),
            ),
          HudButton.ghost(
            label: 'Add set',
            icon: Icons.add,
            compact: true,
            onPressed: onAddSet,
          ),
        ],
      ),
    );
  }
}

class _SetEditor extends StatelessWidget {
  const _SetEditor({
    super.key,
    required this.number,
    required this.set,
    required this.best,
    required this.lastHint,
    required this.onChanged,
    required this.onToggleDone,
  });

  final int number;
  final _SetRow set;
  final double? best;
  final StrengthSet? lastHint;
  final VoidCallback onChanged;
  final VoidCallback onToggleDone;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final e1 = set.warmup ? null : epley1Rm(set.kg, set.repCount);
    final pr = e1 != null && best != null && e1 > best! + 0.05;
    final numFmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    InputDecoration deco(String label, String? hint) => InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );
    final rowColor = set.done
        ? AppColors.success.withValues(alpha: hud.isDark ? 0.09 : 0.08)
        : Colors.transparent;
    return CelebrationBurst(
      controller: set.burst,
      color: AppColors.gold,
      particles: 18,
      spread: 0.6,
      child: AnimatedContainer(
        duration: AppMotion.medium,
        margin: const EdgeInsets.only(bottom: 4, right: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: rowColor,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Semantics(
                button: true,
                label: set.warmup
                    ? 'Set $number, warm-up. Tap to make it a working set'
                    : 'Set $number. Tap to mark as warm-up',
                excludeSemantics: true,
                child: PressableScale(
                  haptic: PressHaptic.selection,
                  onTap: () {
                    set.warmup = !set.warmup;
                    onChanged();
                  },
                  child: Container(
                    height: 36,
                    margin: const EdgeInsets.only(right: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadii.xs),
                      border: Border.all(
                        color: (set.warmup ? AppColors.warning : hud.hairline)
                            .withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      set.warmup ? 'W' : '$number',
                      style: hud
                          .mono(
                            size: 12,
                            color: set.warmup ? AppColors.warning : hud.text,
                          )
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: set.weight,
                onChanged: (_) => onChanged(),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: numFmt,
                decoration: deco(
                  'kg',
                  lastHint?.weightKg == null
                      ? null
                      : Fmt.oneDp(lastHint!.weightKg!),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: TextField(
                controller: set.reps,
                onChanged: (_) => onChanged(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: deco('reps', lastHint?.reps?.toString()),
              ),
            ),
            SizedBox(
              width: 52,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Semantics(
                    button: true,
                    checked: set.done,
                    label: 'Set $number done',
                    excludeSemantics: true,
                    child: PressableScale(
                      haptic: PressHaptic.none,
                      pressedScale: 0.88,
                      onTap: onToggleDone,
                      child: AnimatedContainer(
                        duration: AppMotion.short,
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: set.done
                              ? AppColors.success.withValues(alpha: 0.22)
                              : Colors.transparent,
                          border: Border.all(
                            color: set.done
                                ? AppColors.success
                                : hud.hairline.withValues(alpha: 0.35),
                            width: set.done ? 1.6 : 1,
                          ),
                          boxShadow: set.done
                              ? AppGlows.soft(
                                  AppColors.success,
                                  strength: hud.glowStrength,
                                )
                              : null,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 20,
                          color: set.done ? AppColors.success : hud.textMuted,
                        ),
                      ),
                    ),
                  ),
                  if (pr)
                    Positioned(
                      top: -6,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.gold,
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: AppGlows.soft(
                            AppColors.gold,
                            strength: hud.glowStrength,
                          ),
                        ),
                        child: Text(
                          'PR',
                          style: t.labelSmall?.copyWith(
                            color: const Color(0xFF231600),
                            fontWeight: FontWeight.w800,
                            fontSize: 9,
                          ),
                        ),
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
}

/// Floating reactor-ring countdown. Drains as rest passes; at zero it flips
/// to "GO" with the goal-reached haptic.
class _RestTimerPanel extends StatelessWidget {
  const _RestTimerPanel({
    required this.controller,
    required this.total,
    required this.done,
    required this.label,
    required this.onMinus,
    required this.onPlus,
    required this.onSkip,
  });

  final AnimationController controller;
  final Duration total;
  final bool done;
  final String? label;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final c = done ? AppColors.success : hud.accent;
    return GlassPanel(
      blur: 18,
      glow: true,
      accent: c,
      radius: AppRadii.xl,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final leftMs = done
              ? 0
              : (total.inMilliseconds * (1 - controller.value)).ceil();
          final secs = (leftMs / 1000).ceil();
          final text =
              '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
          return Semantics(
            liveRegion: true,
            label: done ? 'Rest done' : 'Rest, $text remaining',
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 64,
                  child: CustomPaint(
                    painter: ReactorRingPainter(
                      value: done ? 1 : 1 - controller.value,
                      color: c,
                      stroke: 6,
                      hud: hud,
                    ),
                    child: Center(
                      child: Text(
                        done ? 'GO' : text,
                        style: hud.number(size: done ? 18 : 15, color: c),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        done ? 'REST DONE' : 'RESTING',
                        style: hud.label(size: 11, color: c),
                      ),
                      Text(
                        done ? 'Next set. Go.' : (label ?? 'Next set'),
                        style: t.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!done) ...[
                  _TimerButton(label: '−15', onTap: onMinus),
                  _TimerButton(label: '+15', onTap: onPlus),
                ],
                IconButton(
                  tooltip: done ? 'Dismiss' : 'Skip rest',
                  onPressed: onSkip,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TimerButton extends StatelessWidget {
  const _TimerButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      button: true,
      label: '$label seconds',
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.none,
        pressedScale: 0.9,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: Text(
            label,
            style: hud
                .mono(size: 12, color: hud.accentInk)
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// Paste-CSV sheet for Hevy's official export (a file picker requires the
/// `file_picker` package, not yet in pubspec).
Future<void> showCsvImportDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final result = await showHudBottomSheet<String>(
    context,
    title: 'Import Hevy CSV',
    builder: (ctx) => _CsvSheet(controller: controller),
  );
  controller.dispose();
  if (result == null || result.trim().isEmpty) return;
  final summary = await ref.read(csvImportServiceProvider).importText(result);
  if (!context.mounted) return;
  if (summary.imported > 0) Haptics.success();
  final warn = summary.warnings.isEmpty
      ? ''
      : ' (${summary.warnings.length} row(s) skipped: '
            '${summary.warnings.first})';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Imported ${summary.imported} workouts$warn')),
  );
}

class _CsvSheet extends StatelessWidget {
  const _CsvSheet({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HudSteps(
          steps: [
            HudStep(
              'Export from Hevy',
              'Profile → Settings → Export & Import Data → Export workouts.',
            ),
            HudStep(
              'Copy the CSV',
              'Open the file, select everything and copy it.',
            ),
            HudStep(
              'Paste below',
              'Re-importing the same file never creates duplicates.',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: controller,
          maxLines: 6,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: 'title,start_time,end_time,…',
          ),
          style: hud.mono(size: 12, color: hud.text),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: 'Import',
          icon: Icons.upload,
          expand: true,
          onPressed: () => Navigator.pop(context, controller.text),
        ),
      ],
    );
  }
}
