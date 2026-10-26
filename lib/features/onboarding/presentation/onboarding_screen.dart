import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../today/presentation/widgets/briefing.dart' show Typewriter;
import '../../life/application/notifications/notification_providers.dart';
import '../../life/domain/habit_models.dart';
import '../../planning/application/planning_providers.dart';
import '../application/persona_providers.dart';
import '../data/calibration_service.dart';
import '../domain/calibration.dart';
import '../domain/nutrition_calculator.dart';
import 'plan_summary.dart';
import 'widgets/calibration_widgets.dart';

/// JARVIS calibration: one question per screen, every answer pre-filled from
/// the interview so the user can tap Next. Nothing is persisted until Engage.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.onFinished});

  /// Called after Engage succeeded. Defaults to going to Today (GoRouter) or
  /// popping.
  final VoidCallback? onFinished;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _Step {
  const _Step(this.id, this.kicker, this.title, this.subtitle);
  final String id;
  final String kicker;
  final String title;
  final String subtitle;
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  CalibrationAnswers _a = CalibrationAnswers.interviewDefaults();
  int _step = 0;
  bool _forward = true;
  bool _engaging = false;
  bool _online = false;
  bool _loaded = false;
  final _burst = CelebrationController();

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Recalibration starts from the saved answers.
    unawaited(
      ref.read(personaRepositoryProvider).calibration().then((saved) {
        if (!mounted) return;
        setState(() {
          if (saved != null) _a = saved;
          _loaded = true;
        });
      }, onError: (_) => setState(() => _loaded = true)),
    );
  }

  String get _addr => _a.addressAs.isEmpty ? _a.name : _a.addressAs;

  List<_Step> get _steps => [
    const _Step(
      'welcome',
      'JARVIS · ONLINE',
      'Good to meet you properly.',
      'A short calibration so I can run your training, nutrition and day. '
          'I have pre-filled everything from our conversation — tap Next '
          'unless something has changed.',
    ),
    const _Step(
      'name',
      'IDENTITY',
      'What should I call you?',
      'I will use this in briefings and reminders.',
    ),
    _Step(
      'goal',
      'OBJECTIVE',
      'What is the mission, $_addr?',
      'This sets the direction of your calories.',
    ),
    const _Step(
      'competition',
      'COMPETITION',
      'Which category, and is there a date?',
      'No date yet is perfectly fine — I will plan the prep once there is.',
    ),
    const _Step(
      'diet',
      'FUEL',
      'How do you eat?',
      'Meal ideas and examples follow this. Add anything you avoid.',
    ),
    const _Step(
      'experience',
      'EXPERIENCE',
      'How long have you trained seriously?',
      'This tunes volume and how fast loads progress.',
    ),
    const _Step(
      'body',
      'BIOMETRICS',
      'Current weight and body fat.',
      'Estimates are fine. I use lean mass for energy and protein.',
    ),
    const _Step(
      'rate',
      'PACE',
      'How quickly should we cut?',
      '0.5–1 % of body weight per week. Slower protects muscle on a long '
          'prep.',
    ),
    const _Step(
      'schedule',
      'SCHEDULE',
      'Your day, in hours.',
      'I will fit training, meals and focus blocks around these.',
    ),
    const _Step(
      'split',
      'TRAINING',
      'How do you want to train each week?',
      'You asked for no rest days. Sunday becomes a lighter weak-point '
          'pump, and every 6th week is a deload.',
    ),
    const _Step(
      'run',
      'RUNNING',
      'Your running goal.',
      'Paces for easy, tempo and interval runs come from this.',
    ),
    const _Step(
      'daily',
      'DAILY TARGETS',
      'Steps and water.',
      'Both count toward your energy estimate.',
    ),
    const _Step(
      'persona',
      'PERSONA',
      'How should I sound?',
      'Personality applies to briefings and the AI coach.',
    ),
    const _Step(
      'rituals',
      'WELL-BEING',
      'Which rituals shall I run?',
      'Only what you select gets a reminder.',
    ),
    const _Step(
      'habits',
      'HABITS',
      'Which habits should I track?',
      'Added to your habit board; existing ones are never duplicated.',
    ),
    const _Step(
      'messaging',
      'MESSAGES',
      'Which apps should I watch?',
      'Saved as a preference for the messaging assistant. Nothing is read '
          'until you grant notification access there.',
    ),
    const _Step(
      'wearable',
      'SENSORS',
      'Wearable status?',
      'Without a watch I lean on phone steps and your check-ins.',
    ),
    _Step(
      'plan',
      'YOUR PLAN',
      'Calibration complete, $_addr.',
      'Here is what I will set up. Every number is an estimate I will '
          'refine from your weekly trend.',
    ),
  ];

  void _go(int to) {
    if (to < 0 || to >= _steps.length) return;
    FocusScope.of(context).unfocus();
    Haptics.selection();
    setState(() {
      _forward = to > _step;
      _step = to;
    });
  }

  void _set(CalibrationAnswers a) => setState(() => _a = a);

  Future<void> _engage() async {
    setState(() => _engaging = true);
    try {
      final tz = await ref
          .read(deviceTimeZoneProvider.future)
          .timeout(const Duration(seconds: 2), onTimeout: () => null)
          .catchError((_) => null);
      final result = await ref
          .read(calibrationServiceProvider)
          .engage(_a, tzName: tz ?? 'Asia/Kolkata');
      // Reactor power-up: the systems come online, then we hand over.
      if (mounted) {
        setState(() => _online = true);
        _burst.fire();
        Haptics.goalReached();
        if (!AppMotion.reduced(context)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
      ref.read(onboardingGateProvider.notifier).markDone();
      if (result.remindersEnabled.isNotEmpty) {
        try {
          await ref
              .read(notificationGatewayProvider)
              .requestPermission()
              .timeout(const Duration(seconds: 20));
        } catch (_) {}
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final finished = widget.onFinished;
      if (finished != null) {
        finished();
      } else {
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go(AppPaths.today);
        } else {
          Navigator.of(context).maybePop();
        }
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Calibration complete. At your service, $_addr.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      Haptics.warning();
      setState(() {
        _engaging = false;
        _online = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Calibration could not be saved. Nothing was changed; '
            'try Engage again.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final step = steps[_step];
    final last = _step == steps.length - 1;
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xs,
                    AppSpacing.sm,
                    AppSpacing.xs,
                    0,
                  ),
                  child: Row(
                    children: [
                      // Hidden (not just disabled) on the first step; the
                      // slot keeps the progress arc centred.
                      Visibility(
                        visible: _step > 0,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: IconButton(
                          tooltip: 'Back',
                          onPressed: _step == 0 || _engaging
                              ? null
                              : () => _go(_step - 1),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            SegmentedArcProgress(
                              step: _step,
                              count: steps.length,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Step ${_step + 1} of ${steps.length}',
                              style: hud.mono(size: 10.5),
                            ),
                          ],
                        ),
                      ),
                      Visibility(
                        visible: !last,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: TextButton(
                          onPressed: last || _engaging
                              ? null
                              : () {
                                  Haptics.light();
                                  _go(steps.length - 1);
                                },
                          child: const Text('Skip'),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: reduced ? Duration.zero : AppMotion.long,
                    reverseDuration: reduced
                        ? Duration.zero
                        : AppMotion.pageReverse,
                    switchInCurve: AppMotion.emphasizedDecelerate,
                    switchOutCurve: AppMotion.emphasizedAccelerate,
                    transitionBuilder: (child, anim) {
                      final incoming = child.key == ValueKey(step.id);
                      final dir = _forward ? 1.0 : -1.0;
                      final dx = dir * (incoming ? 36.0 : -36.0);
                      return AnimatedBuilder(
                        animation: anim,
                        child: child,
                        builder: (context, child) {
                          final v = anim.value;
                          return Opacity(
                            opacity: incoming
                                ? Curves.easeIn.transform(
                                    ((v - 0.25) / 0.75).clamp(0.0, 1.0),
                                  )
                                : v,
                            child: Transform.translate(
                              offset: Offset(dx * (1 - v), 0),
                              child: Transform.scale(
                                scale: incoming ? 0.97 + 0.03 * v : 1,
                                child: child,
                              ),
                            ),
                          );
                        },
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(step.id),
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (r) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0, 0.035, 0.96, 1],
                        ).createShader(r),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.gutter,
                            AppSpacing.lg,
                            AppSpacing.gutter,
                            AppSpacing.xxl,
                          ),
                          children: [
                            if (step.id != 'welcome')
                              Stagger(
                                index: 0,
                                child: Row(
                                  children: [
                                    const JarvisOrb(
                                      size: 30,
                                      fps: 30,
                                      state: OrbState.speaking,
                                      semanticLabel: null,
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Text(
                                      'JARVIS · ${step.kicker}',
                                      style: hud.mono(
                                        size: 10.5,
                                        color: hud.accentInk,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              const _WelcomeReactor(),
                            const SizedBox(height: AppSpacing.md),
                            Typewriter(
                              step.title,
                              style: t.headlineSmall,
                              caret: hud.accent,
                              charDelay: const Duration(milliseconds: 22),
                              delay: const Duration(milliseconds: 160),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Stagger(
                              index: 3,
                              child: Text(
                                step.subtitle,
                                style: t.bodyMedium?.copyWith(
                                  color: hud.textMuted,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xl),
                            if (!_loaded && step.id == 'welcome')
                              const Padding(
                                padding: EdgeInsets.only(bottom: AppSpacing.md),
                                child: ScanlineLoader(height: 4, lines: 0),
                              ),
                            ..._body(step.id),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.sm,
                    AppSpacing.gutter,
                    AppSpacing.lg,
                  ),
                  child: HudButton(
                    expand: true,
                    loading: _engaging,
                    icon: last ? Icons.bolt : Icons.arrow_forward,
                    label: last
                        ? 'Engage'
                        : _step == 0
                        ? 'Begin calibration'
                        : 'Next',
                    onPressed: _engaging
                        ? null
                        : last
                        ? _engage
                        : () => _go(_step + 1),
                  ),
                ),
              ],
            ),
          ),
          if (_engaging)
            Positioned.fill(
              child: _PowerUp(online: _online, burst: _burst, name: _addr),
            ),
        ],
      ),
    );
  }

  List<Widget> _staggered(List<Widget> children) => [
    for (var i = 0; i < children.length; i++)
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Stagger(index: i + 3, child: children[i]),
      ),
  ];

  List<Widget> _body(String id) {
    final a = _a;
    switch (id) {
      case 'welcome':
        return _staggered([
          _bullet(Icons.restaurant, 'Calories & macros from your lean mass'),
          _bullet(Icons.fitness_center, '5 lift + 2 run program with deloads'),
          _bullet(Icons.view_timeline, 'A daily routine around your office'),
          _bullet(Icons.self_improvement, 'Check-ins, journal and reviews'),
        ]);
      case 'name':
        return _staggered([
          TextFormField(
            initialValue: a.name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Your name',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              final wasName = a.addressAs == a.name;
              _set(_a.copyWith(name: v, addressAs: wasName ? v : _a.addressAs));
            },
          ),
          for (final opt in {a.name, 'Sir', 'Boss'})
            OptionCard(
              title: opt == a.name ? 'By name — “$opt”' : '“$opt”',
              icon: Icons.record_voice_over_outlined,
              selected: a.addressAs == opt,
              onTap: () => _set(_a.copyWith(addressAs: opt)),
            ),
        ]);
      case 'goal':
        return _staggered([
          for (final g in NutritionGoal.values)
            OptionCard(
              title: g.label,
              subtitle: switch (g) {
                NutritionGoal.cut => 'Lose fat, keep muscle',
                NutritionGoal.leanBulk => 'Slow, controlled gain',
                NutritionGoal.recomp => 'Small deficit, trade fat for muscle',
                NutritionGoal.contestPrep => 'Get stage-lean for a show',
              },
              icon: switch (g) {
                NutritionGoal.cut => Icons.trending_down,
                NutritionGoal.leanBulk => Icons.trending_up,
                NutritionGoal.recomp => Icons.balance,
                NutritionGoal.contestPrep => Icons.emoji_events_outlined,
              },
              selected: a.goal == g,
              onTap: () => _set(_a.copyWith(goal: g)),
            ),
        ]);
      case 'competition':
        return _staggered([
          for (final c in competitionCategories)
            OptionCard(
              title: c,
              icon: c == competitionCategories.last
                  ? Icons.do_not_disturb_on_outlined
                  : Icons.emoji_events_outlined,
              accent: AppColors.gold,
              selected: a.category == c,
              onTap: () => _set(_a.copyWith(category: c)),
            ),
          OptionCard(
            title: a.competitionDate == null
                ? 'No date fixed yet'
                : 'Show date: ${a.competitionDate}',
            subtitle: a.competitionDate == null
                ? 'Tap to pick a date'
                : 'Tap to change · long-press to clear',
            icon: Icons.event_outlined,
            accent: AppColors.gold,
            selected: a.competitionDate != null,
            onTap: _pickCompetitionDate,
          ),
          if (a.competitionDate != null)
            HudButton.ghost(
              onPressed: () => _set(_a.copyWith(competitionDate: () => null)),
              icon: Icons.clear,
              label: 'No date yet',
            ),
        ]);
      case 'diet':
        return _staggered([
          ChoiceChips<String>(
            options: dietTypes,
            labelOf: (d) => d,
            isSelected: (d) => a.dietType == d,
            onTap: (d) => _set(_a.copyWith(dietType: d)),
          ),
          ChipListEditor(
            label: 'Restrictions / allergies',
            hint: 'e.g. lactose intolerance',
            values: a.restrictions,
            suggestions: const ['No onion/garlic', 'Lactose-free'],
            onChanged: (v) => _set(_a.copyWith(restrictions: v)),
          ),
          ChipListEditor(
            label: 'Foods you dislike',
            hint: 'e.g. tofu',
            values: a.dislikes,
            onChanged: (v) => _set(_a.copyWith(dislikes: v)),
          ),
        ]);
      case 'experience':
        return _staggered([
          for (final e in Experience.values)
            OptionCard(
              title: e.label,
              subtitle: e.detail,
              icon: Icons.stacked_line_chart,
              selected: a.experience == e,
              onTap: () => _set(_a.copyWith(experience: e)),
            ),
        ]);
      case 'body':
        final lbm = lbmOf(a.weightKg, a.bodyFatPct);
        return _staggered([
          NumberStepper(
            label: 'Body weight',
            value: a.weightKg,
            step: 0.5,
            min: 40,
            max: 200,
            unit: 'kg',
            onChanged: (v) => _set(_a.copyWith(weightKg: v)),
          ),
          NumberStepper(
            label: 'Body fat',
            value: a.bodyFatPct,
            step: 0.5,
            min: 4,
            max: 50,
            unit: '%',
            helper: 'Lean body mass ≈ ${lbm.toStringAsFixed(1)} kg',
            onChanged: (v) => _set(_a.copyWith(bodyFatPct: v)),
          ),
        ]);
      case 'rate':
        final preview = calculateNutrition(a.nutritionInputs);
        return _staggered([
          for (final r in const [0.5, 0.6, 0.75, 1.0])
            OptionCard(
              title:
                  '${r.toString().replaceAll(RegExp(r'\.?0+$'), '')} % '
                  'per week',
              subtitle:
                  '≈ ${(a.weightKg * r / 100).toStringAsFixed(2)} kg/week'
                  '${r == 0.6 ? ' · recommended' : ''}',
              icon: Icons.speed,
              selected: (a.weeklyRatePct - r).abs() < 0.001,
              onTap: () => _set(_a.copyWith(weeklyRatePct: r)),
            ),
          _PreviewPill(
            text:
                '≈ ${preview.targetKcal} kcal/day · '
                '${preview.deficitPct.toStringAsFixed(0)} % below maintenance',
          ),
        ]);
      case 'schedule':
        return _staggered([
          TimeTile(
            label: 'Wake up',
            icon: Icons.wb_twilight,
            minutes: a.wakeMinutes,
            onChanged: (v) => _set(_a.copyWith(wakeMinutes: v)),
          ),
          TimeTile(
            label: 'Training starts',
            icon: Icons.fitness_center,
            minutes: a.trainingStart,
            onChanged: (v) => _set(_a.copyWith(trainingStart: v)),
          ),
          TimeTile(
            label: 'Office starts',
            icon: Icons.work_outline,
            minutes: a.officeStart,
            onChanged: (v) => _set(_a.copyWith(officeStart: v)),
          ),
          TimeTile(
            label: 'Office ends',
            icon: Icons.work_history_outlined,
            minutes: a.officeEnd,
            onChanged: (v) => _set(_a.copyWith(officeEnd: v)),
          ),
          TimeTile(
            label: 'Sleep',
            icon: Icons.bedtime_outlined,
            minutes: a.sleepMinutes,
            onChanged: (v) => _set(_a.copyWith(sleepMinutes: v)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OFFICE DAYS', style: context.hud.label(size: 11)),
              const SizedBox(height: AppSpacing.sm),
              ChoiceChips<int>(
                spread: true,
                options: const [1, 2, 3, 4, 5, 6, 7],
                labelOf: (d) => weekdayShort[d - 1].substring(0, 2),
                isSelected: (d) => maskHasWeekday(a.officeDaysMask, d),
                onTap: (d) => _set(
                  _a.copyWith(
                    officeDaysMask: maskHasWeekday(a.officeDaysMask, d)
                        ? a.officeDaysMask & ~weekdayBit(d)
                        : a.officeDaysMask | weekdayBit(d),
                  ),
                ),
              ),
            ],
          ),
        ]);
      case 'split':
        return _staggered([
          for (final s in const [(5, 2), (4, 2), (4, 1)])
            OptionCard(
              title: '${s.$1} lift + ${s.$2} run',
              subtitle: s.$1 + s.$2 == 7
                  ? 'Every day · Sunday is a lighter pump'
                  : '${7 - s.$1 - s.$2} rest day(s)',
              icon: Icons.calendar_view_week,
              selected: a.liftDays == s.$1 && a.runDays == s.$2,
              onTap: () => _set(_a.copyWith(liftDays: s.$1, runDays: s.$2)),
            ),
          const _PreviewPill(
            text:
                'Mon Push · Tue Pull · Wed Easy run · Thu Legs + abs · '
                'Fri Upper · Sat 5K session · Sun Weak-point pump',
          ),
        ]);
      case 'run':
        return _staggered([
          SegmentedHud<int>(
            segments: const [
              HudSegment(value: 5000, label: '5K'),
              HudSegment(value: 10000, label: '10K'),
            ],
            value: a.runGoalDistanceM,
            onChanged: (d) => _set(_a.copyWith(runGoalDistanceM: d)),
          ),
          NumberStepper(
            label: 'Target time',
            value: a.runGoalTimeS / 60,
            step: 0.5,
            min: 12,
            max: 120,
            format: (v) {
              final s = (v * 60).round();
              return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
            },
            unit: 'min',
            helper:
                'Goal pace ${_pace(a.runGoalTimeS, a.runGoalDistanceM)} /km',
            onChanged: (v) => _set(_a.copyWith(runGoalTimeS: (v * 60).round())),
          ),
        ]);
      case 'daily':
        return _staggered([
          NumberStepper(
            label: 'Daily steps',
            value: a.stepGoal.toDouble(),
            step: 500,
            min: 2000,
            max: 30000,
            onChanged: (v) => _set(_a.copyWith(stepGoal: v.round())),
          ),
          NumberStepper(
            label: 'Water',
            value: a.waterGoalMl / 1000,
            step: 0.25,
            min: 1,
            max: 6,
            unit: 'L',
            format: (v) => v.toStringAsFixed(2).replaceAll(RegExp(r'0$'), ''),
            onChanged: (v) =>
                _set(_a.copyWith(waterGoalMl: (v * 1000).round())),
          ),
        ]);
      case 'persona':
        return _staggered([
          TextFormField(
            initialValue: a.personaName,
            decoration: const InputDecoration(
              labelText: 'Assistant name',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _set(_a.copyWith(personaName: v)),
          ),
          ChoiceChips<String>(
            options: const [
              'calm',
              'witty',
              'formal',
              'warm',
              'blunt',
              'motivational',
            ],
            labelOf: (t) => t,
            isSelected: (t) => a.personaTraits.contains(t),
            onTap: (trait) => _set(
              _a.copyWith(
                personaTraits: a.personaTraits.contains(trait)
                    ? a.personaTraits.where((x) => x != trait).toList()
                    : [...a.personaTraits, trait],
              ),
            ),
          ),
          OptionCard(
            title: 'Voice responses',
            subtitle: 'Briefings and coach replies, read aloud',
            icon: Icons.graphic_eq,
            multi: true,
            selected: a.voiceEnabled,
            onTap: () => _set(_a.copyWith(voiceEnabled: !a.voiceEnabled)),
          ),
        ]);
      case 'rituals':
        return _staggered([
          for (final r in Ritual.values)
            OptionCard(
              title: r.label,
              subtitle: r.detail,
              icon: switch (r) {
                Ritual.moodCheckIn => Icons.mood,
                Ritual.journal => Icons.edit_note,
                Ritual.morningBriefing => Icons.wb_sunny_outlined,
                Ritual.eveningReview => Icons.nightlight_outlined,
                Ritual.focusBlocks => Icons.center_focus_strong,
                Ritual.water => Icons.water_drop_outlined,
                Ritual.workout => Icons.alarm,
              },
              multi: true,
              selected: a.rituals.contains(r),
              onTap: () => _set(_a.copyWith(rituals: _toggle(a.rituals, r))),
            ),
        ]);
      case 'habits':
        return _staggered([
          for (final h in SeedHabit.values)
            OptionCard(
              title: h == SeedHabit.sleepOnTime
                  ? 'Lights out by ${hhmm(a.sleepMinutes)}'
                  : h.label,
              icon: Icons.check_circle_outline,
              multi: true,
              selected: a.habits.contains(h),
              onTap: () => _set(_a.copyWith(habits: _toggle(a.habits, h))),
            ),
        ]);
      case 'messaging':
        return _staggered([
          for (final m in messagingAppChoices)
            OptionCard(
              title: m.label,
              icon: switch (m.packageName) {
                'com.google.android.gm' => Icons.mail_outline,
                'com.google.android.apps.messaging' => Icons.sms_outlined,
                'com.instagram.android' => Icons.photo_camera_outlined,
                'com.twitter.android' => Icons.alternate_email,
                'org.telegram.messenger' => Icons.send_outlined,
                'com.Slack' => Icons.tag,
                _ => Icons.chat_bubble_outline,
              },
              multi: true,
              selected: a.messagingApps.contains(m.packageName),
              onTap: () => _set(
                _a.copyWith(
                  messagingApps: a.messagingApps.contains(m.packageName)
                      ? a.messagingApps
                            .where((p) => p != m.packageName)
                            .toList()
                      : [...a.messagingApps, m.packageName],
                ),
              ),
            ),
        ]);
      case 'wearable':
        return _staggered([
          for (final w in WearableStatus.values)
            OptionCard(
              title: w.label,
              subtitle: w.detail,
              icon: w == WearableStatus.phoneOnly
                  ? Icons.smartphone
                  : Icons.watch_outlined,
              selected: a.wearable == w,
              onTap: () => _set(_a.copyWith(wearable: w)),
            ),
        ]);
      case 'plan':
        return [
          PlanSummaryView(
            answers: a,
            plan: calculateNutrition(a.nutritionInputs),
          ),
        ];
    }
    return const [];
  }

  Set<T> _toggle<T>(Set<T> s, T v) =>
      s.contains(v) ? ({...s}..remove(v)) : {...s, v};

  Future<void> _pickCompetitionDate() async {
    final now = ref.read(clockProvider).now();
    final initial = _a.competitionDate == null
        ? now.add(const Duration(days: 7 * 22))
        : LocalDates.parse(_a.competitionDate!);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
    );
    if (picked != null) {
      _set(_a.copyWith(competitionDate: () => LocalDates.key(picked)));
    }
  }

  Widget _bullet(IconData icon, String text) => GlassPanel(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.md,
    ),
    child: Row(
      children: [
        GlowIcon(icon, size: 18),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}

String _pace(int timeS, int distanceM) {
  final p = (timeS / distanceM * 1000).round();
  return '${p ~/ 60}:${(p % 60).toString().padLeft(2, '0')}';
}

class _PreviewPill extends StatelessWidget {
  const _PreviewPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return AnimatedSwitcher(
      duration: AppMotion.medium,
      child: GlassPanel(
        key: ValueKey(text),
        accent: hud.accent,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            GlowIcon(Icons.auto_awesome, size: 18, color: hud.accent),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Welcome: the reactor orb inside a ticked HUD frame.
class _WelcomeReactor extends StatelessWidget {
  const _WelcomeReactor();

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return Center(
      child: Entrance(
        enabled: !reduced,
        fromScale: 0.7,
        blur: 10,
        duration: const Duration(milliseconds: 900),
        offset: Offset.zero,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: HudFrame(
            cornerLength: 18,
            ticks: true,
            tag: 'CAL·01',
            padding: EdgeInsets.all(AppSpacing.lg),
            child: JarvisOrb(size: 168, semanticLabel: 'JARVIS'),
          ),
        ),
      ),
    );
  }
}

/// Full-screen "reactor power-up" while calibration is saved; bursts when
/// the systems come online.
class _PowerUp extends StatelessWidget {
  const _PowerUp({
    required this.online,
    required this.burst,
    required this.name,
  });

  final bool online;
  final CelebrationController burst;
  final String name;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.long,
      curve: AppMotion.emphasizedDecelerate,
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: ColoredBox(
        color: hud.canvasBottom.withValues(alpha: 0.88),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CelebrationBurst(
                controller: burst,
                color: hud.accent,
                child: JarvisOrb(
                  size: 200,
                  state: online ? OrbState.speaking : OrbState.thinking,
                  semanticLabel: online ? 'Systems online' : 'Engaging',
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                online ? 'SYSTEMS ONLINE' : 'ENGAGING',
                style: hud.label(size: 13, color: hud.accentInk),
              ),
              const SizedBox(height: AppSpacing.sm),
              AnimatedSwitcher(
                duration: AppMotion.medium,
                child: Text(
                  online
                      ? 'At your service, $name.'
                      : 'Writing targets, program and routine…',
                  key: ValueKey(online),
                  style: t.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
