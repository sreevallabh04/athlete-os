import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../data/calibration_service.dart';
import '../domain/calibration.dart';
import '../domain/nutrition_calculator.dart';
import '../domain/training_program.dart';

/// "Your plan" — computed numbers with plain-language explanations, shown
/// before Engage. Read-only; nothing is written here.
class PlanSummaryView extends StatelessWidget {
  const PlanSummaryView({super.key, required this.answers, required this.plan});

  final CalibrationAnswers answers;
  final NutritionPlan plan;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final a = answers;
    final p = plan;
    final zones = PaceZones.fromGoal(a.runGoalDistanceM, a.runGoalTimeS);
    final rituals = [
      for (final r in Ritual.values)
        if (a.rituals.contains(r)) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          accent: AppColors.calories,
          child: Column(
            children: [
              Text(
                'DAILY TARGET',
                style: t.labelMedium?.copyWith(
                  letterSpacing: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: p.targetKcal.toDouble()),
                duration: AppDurations.slow * 2,
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Text(
                  '${_thousands(v.round())} kcal',
                  key: const ValueKey('plan-kcal'),
                  style: t.displaySmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                'Maintenance ≈ ${_thousands(p.maintenanceLow)}–'
                '${_thousands(p.maintenanceHigh)} kcal · '
                '${p.dailyDeficit >= 0 ? '−' : '+'}'
                '${p.dailyDeficit.abs()} kcal/day '
                '(${p.deficitPct.abs().toStringAsFixed(0)} %)',
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  _Macro('Protein', p.proteinG, AppColors.protein),
                  _Macro('Carbs', p.carbsG, AppColors.carbs),
                  _Macro('Fat', p.fatG, AppColors.fat),
                ],
              ),
            ],
          ),
        ),
        for (final w in p.warnings) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            message: w.message,
            icon: Icons.warning_amber_rounded,
            color: AppColors.warning,
          ),
        ],
        const SectionHeader('How I got these numbers'),
        AppCard(
          child: Column(
            children: [
              _Row(
                'Lean body mass',
                '${p.lbmKg.toStringAsFixed(1)} kg',
                '${a.weightKg} kg × (1 − ${a.bodyFatPct} %)',
              ),
              _Row(
                'BMR (Katch-McArdle)',
                '${p.bmr.round()} kcal',
                '370 + 21.6 × LBM',
              ),
              _Row(
                'Activity',
                '× ${p.activityMultiplier.toStringAsFixed(2)}',
                '${a.job.label}, ${_thousands(a.stepGoal)} steps, '
                    '${a.liftDays} lifts + ${a.runDays} runs/week',
              ),
              _Row(
                'Maintenance',
                '≈ ${_thousands(p.maintenance)} kcal',
                'Range ${_thousands(p.maintenanceLow)}–'
                    '${_thousands(p.maintenanceHigh)}; refined from your trend',
              ),
              _Row(
                'Rate',
                '${p.weeklyChangeKg.toStringAsFixed(2)} kg/week',
                '${a.weeklyRatePct} % of body weight × 7,700 kcal/kg',
              ),
              _Row(
                'Protein',
                '${p.proteinG} g',
                '≈ ${(p.proteinG / p.lbmKg).toStringAsFixed(1)} g/kg lean '
                    'mass (lean dieters: 2.3–3.1)',
              ),
              _Row(
                'Fat',
                '${p.fatG} g',
                '≥ 0.8 g/kg body weight and ≥ 20 % of calories',
              ),
              _Row('Carbs', '${p.carbsG} g', 'The remainder — fuels training'),
              if (a.goal.isDeficit)
                _Row(
                  'Stage weight',
                  '${p.stageWeightLowKg.toStringAsFixed(1)}–'
                      '${p.stageWeightHighKg.toStringAsFixed(1)} kg',
                  'At 6–8 % body fat if lean mass is kept',
                ),
              if (a.goal.isDeficit)
                _Row(
                  'Prep length',
                  '${p.prepWeeksMin}–${p.prepWeeksMax} weeks',
                  'Plus a 1–2-week buffer before the show',
                  last: true,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          NutritionPlan.disclaimer,
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SectionHeader('Training week'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final d in const [
              ('Mon', 'Push'),
              ('Tue', 'Pull'),
              ('Wed', 'Easy run'),
              ('Thu', 'Legs + abs'),
              ('Fri', 'Upper'),
              ('Sat', '5K session'),
              ('Sun', 'Pump'),
            ])
              Chip(
                avatar: Icon(
                  d.$2.contains('run') || d.$2.contains('5K')
                      ? Icons.directions_run
                      : Icons.fitness_center,
                  size: 16,
                ),
                label: Text('${d.$1} · ${d.$2}'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Deload every 6th week (−40 % volume). Easy runs '
          '${formatPaceRange(zones.easy.$1, zones.easy.$2)}, goal pace '
          '${formatPaceRange(zones.goal.$1, zones.goal.$2)} (estimates).',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SectionHeader('I will set up'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Setup(
                Icons.person_outline,
                'Profile targets: ${_thousands(a.stepGoal)} steps, '
                '${(a.waterGoalMl / 1000).toStringAsFixed(1)} L water, '
                'wake ${hhmm(a.wakeMinutes)}, sleep ${hhmm(a.sleepMinutes)}',
              ),
              for (final r in rituals)
                _Setup(Icons.notifications_active_outlined, _ritualLine(r, a)),
              for (final h in a.habits)
                _Setup(
                  Icons.check_circle_outline,
                  'Habit: ${h == SeedHabit.sleepOnTime ? 'Lights out by ${hhmm(a.sleepMinutes)}' : h.label}',
                ),
              if (a.hasCompetition)
                _Setup(
                  Icons.emoji_events_outlined,
                  '${a.category} on ${a.competitionDate}',
                ),
              if (a.messagingApps.isNotEmpty)
                _Setup(
                  Icons.chat_bubble_outline,
                  'Watch list: ${[for (final m in messagingAppChoices)
                    if (a.messagingApps.contains(m.packageName)) m.label].join(', ')}',
                ),
              _Setup(
                Icons.smartphone,
                'Sensors: ${a.wearable.label.toLowerCase()}',
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _ritualLine(Ritual r, CalibrationAnswers a) {
    final fixed = ritualReminderTimes[r];
    if (fixed != null) return '${r.label} at ${hhmm(fixed.$2)}';
    return switch (r) {
      Ritual.water =>
        'Water reminders every 90 min, '
            '${hhmm(a.wakeMinutes)}–${hhmm(a.sleepMinutes)}',
      Ritual.workout =>
        'Workout reminder at ${hhmm(a.trainingStart - 30)} '
            'on training days',
      Ritual.focusBlocks => 'Focus blocks & top-3 priorities in your routine',
      _ => r.label,
    };
  }
}

String _thousands(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

class _Macro extends StatelessWidget {
  const _Macro(this.label, this.grams, this.color);
  final String label;
  final int grams;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          ProgressRing(
            progress: 1,
            color: color,
            size: 64,
            stroke: 6,
            center: Text('$grams', style: t.titleMedium),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('$label (g)', style: t.labelMedium),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, this.why, {this.last = false});
  final String label;
  final String value;
  final String why;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.labelLarge),
                Text(
                  why,
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(value, style: t.titleSmall),
        ],
      ),
    );
  }
}

class _Setup extends StatelessWidget {
  const _Setup(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
