import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
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
  bool _loaded = false;

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
    } catch (e) {
      if (!mounted) return;
      setState(() => _engaging = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Calibration could not be saved: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final step = steps[_step];
    final last = _step == steps.length - 1;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final progress = (_step + 1) / steps.length;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.sm,
                AppSpacing.sm,
                0,
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: _step == 0 ? null : () => _go(_step - 1),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: progress),
                            duration: AppDurations.medium,
                            curve: Curves.easeOutCubic,
                            builder: (_, v, _) => LinearProgressIndicator(
                              value: v,
                              minHeight: 6,
                              backgroundColor: scheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Step ${_step + 1} of ${steps.length}',
                          style: t.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: last ? null : () => _go(steps.length - 1),
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppDurations.medium,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  final incoming = child.key == ValueKey(step.id);
                  final dx = (_forward ? 1 : -1) * (incoming ? 0.12 : -0.12);
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: Offset(dx, 0),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey(step.id),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter,
                      AppSpacing.lg,
                      AppSpacing.gutter,
                      AppSpacing.xxl,
                    ),
                    children: [
                      Stagger(
                        index: 0,
                        child: Text(
                          step.kicker,
                          style: t.labelMedium?.copyWith(
                            color: scheme.primary,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Stagger(
                        index: 1,
                        child: Text(
                          step.title,
                          style: t.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Stagger(
                        index: 2,
                        child: Text(
                          step.subtitle,
                          style: t.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      if (!_loaded && step.id == 'welcome')
                        const LinearProgressIndicator(minHeight: 2),
                      ..._body(step.id),
                    ],
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
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: _engaging
                      ? null
                      : last
                      ? _engage
                      : () => _go(_step + 1),
                  icon: _engaging
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(last ? Icons.bolt : Icons.arrow_forward),
                  label: Text(
                    last
                        ? 'Engage'
                        : _step == 0
                        ? 'Begin calibration'
                        : 'Next',
                  ),
                ),
              ),
            ),
          ],
        ),
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
          const _JarvisOrb(),
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
              title: opt == a.name ? 'By name — "$opt"' : '"$opt"',
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
                NutritionGoal.recomp => 'Small deficit, recomposition',
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
            selected: a.competitionDate != null,
            onTap: _pickCompetitionDate,
          ),
          if (a.competitionDate != null)
            TextButton.icon(
              onPressed: () => _set(_a.copyWith(competitionDate: () => null)),
              icon: const Icon(Icons.clear),
              label: const Text('No date yet'),
            ),
        ]);
      case 'diet':
        return _staggered([
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final d in dietTypes)
                ChoiceChip(
                  label: Text(d[0].toUpperCase() + d.substring(1)),
                  selected: a.dietType == d,
                  onSelected: (_) => _set(_a.copyWith(dietType: d)),
                ),
            ],
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
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1]),
                  selected: maskHasWeekday(a.officeDaysMask, d),
                  onSelected: (on) => _set(
                    _a.copyWith(
                      officeDaysMask: on
                          ? a.officeDaysMask | weekdayBit(d)
                          : a.officeDaysMask & ~weekdayBit(d),
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
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final d in const [5000, 10000])
                ChoiceChip(
                  label: Text('${d ~/ 1000}K'),
                  selected: a.runGoalDistanceM == d,
                  onSelected: (_) => _set(_a.copyWith(runGoalDistanceM: d)),
                ),
            ],
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
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final trait in const [
                'calm',
                'witty',
                'formal',
                'warm',
                'blunt',
                'motivational',
              ])
                FilterChip(
                  label: Text(trait),
                  selected: a.personaTraits.contains(trait),
                  onSelected: (on) => _set(
                    _a.copyWith(
                      personaTraits: on
                          ? [...a.personaTraits, trait]
                          : a.personaTraits.where((x) => x != trait).toList(),
                    ),
                  ),
                ),
            ],
          ),
          OptionCard(
            title: 'Voice responses',
            subtitle: 'Spoken briefings when the voice feature ships',
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
              icon: Icons.chat_bubble_outline,
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

  Widget _bullet(IconData icon, String text) => Row(
    children: [
      Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: AppSpacing.md),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
    ],
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
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: AppDurations.medium,
      child: Container(
        key: ValueKey(text),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

/// Glowing "JARVIS" orb on the welcome step (token colours only). Animates
/// once on entry so tests can settle.
class _JarvisOrb extends StatelessWidget {
  const _JarvisOrb();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1200),
        curve: Curves.easeOutBack,
        builder: (context, v, child) => Transform.scale(
          scale: 0.6 + 0.4 * v,
          child: Container(
            width: 120,
            height: 120,
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.9),
                  scheme.primary.withValues(alpha: 0.15),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(
                    alpha: (0.45 * v).clamp(0.0, 1.0),
                  ),
                  blurRadius: 12 + 36 * v,
                  spreadRadius: 2 + 6 * v,
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: Icon(Icons.blur_on, size: 56, color: scheme.onPrimary),
      ),
    );
  }
}
