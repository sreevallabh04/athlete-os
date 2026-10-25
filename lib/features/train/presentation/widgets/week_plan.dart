import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../onboarding/domain/training_program.dart';
import '../../domain/running_models.dart';
import '../../domain/strength_models.dart';
import 'hud_kit.dart';

/// Colour of a session family (lift = strength, run = running, pump/posing =
/// habit).
Color sessionColor(SessionKind k) => switch (k) {
  SessionKind.lift => AppColors.strength,
  SessionKind.run => AppColors.running,
  SessionKind.recovery => AppColors.habit,
};

IconData sessionIcon(SessionKind k) => switch (k) {
  SessionKind.lift => Icons.fitness_center,
  SessionKind.run => Icons.directions_run,
  SessionKind.recovery => Icons.self_improvement,
};

/// One-word label for compact day cells ("Push", "Easy", "5K", "Pump").
String shortSessionTitle(String title) {
  final lower = title.toLowerCase();
  if (lower.contains('pump')) return 'Pump';
  final first = title.split(RegExp(r'[\s·]+')).first;
  return first.isEmpty ? title : first;
}

enum DayState {
  /// A matching session was logged.
  done,

  /// Today, not logged yet.
  today,

  /// In the past, not logged, while the user was already tracking.
  missed,

  /// In the past before any tracking existed (first run): no judgement.
  untracked,

  /// Later this week.
  upcoming,
}

/// A planned day with what actually happened.
class PlanDay {
  const PlanDay({
    required this.date,
    required this.day,
    required this.state,
    this.workout,
    this.run,
  });
  final String date;
  final ProgramDay day;
  final DayState state;
  final WorkoutLog? workout;
  final RunActivity? run;

  bool get done => state == DayState.done;
}

/// The Monday-based week containing [today], matched against real logs.
///
/// A lift/pump day is done when any strength workout was logged that date;
/// a run day when any run was logged. Past days are "missed" only when the
/// user had already logged something before that date (so a first run never
/// opens with a wall of red).
List<PlanDay> planWeek({
  required TrainingProgram program,
  required String today,
  required List<WorkoutLog> workouts,
  required List<RunActivity> activities,
}) {
  final monday = LocalDates.weekStart(today);
  final byDateW = <String, WorkoutLog>{};
  for (final w in workouts) {
    byDateW.putIfAbsent(w.localDate, () => w);
  }
  final byDateR = <String, RunActivity>{};
  for (final a in activities) {
    if (a.isRun) byDateR.putIfAbsent(a.localDate, () => a);
  }
  final firstLog = [
    ...workouts.map((w) => w.localDate),
    ...activities.where((a) => a.isRun).map((a) => a.localDate),
  ].fold<String?>(null, (m, d) => m == null || d.compareTo(m) < 0 ? d : m);
  return [
    for (var i = 0; i < 7; i++)
      () {
        final date = LocalDates.addDays(monday, i);
        final day = program.sessionFor(date);
        final w = byDateW[date];
        final r = byDateR[date];
        final done = day.kind == SessionKind.run ? r != null : w != null;
        final cmp = date.compareTo(today);
        final state = done
            ? DayState.done
            : cmp == 0
            ? DayState.today
            : cmp > 0
            ? DayState.upcoming
            : (firstLog != null && firstLog.compareTo(date) < 0)
            ? DayState.missed
            : DayState.untracked;
        return PlanDay(date: date, day: day, state: state, workout: w, run: r);
      }(),
  ];
}

/// Seven connected reactor nodes (Mon → Sun) for the week HUD. The rail
/// fills up to today; done nodes glow in their session colour, today pulses
/// cyan, missed nodes are hollow amber.
class WeekNodes extends StatelessWidget {
  const WeekNodes({
    super.key,
    required this.days,
    required this.today,
    this.selected,
    this.onSelect,
    this.showTitles = true,
  });

  final List<PlanDay> days;
  final String today;
  final String? selected;
  final ValueChanged<String>? onSelect;
  final bool showTitles;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final todayIndex = days.indexWhere((d) => d.date == today);
    final doneCount = days.where((d) => d.done).length;
    return Semantics(
      label:
          'This week: $doneCount of ${days.length} planned sessions done. '
          '${days.map((d) => '${weekdayShort[days.indexOf(d)]} ${d.day.title} ${d.state.name}').join(', ')}',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final cell = box.maxWidth / 7;
          return Stack(
            children: [
              // Rail behind the nodes.
              Positioned(
                left: cell / 2,
                right: cell / 2,
                top: 18 + 17,
                child: _Rail(
                  progress: todayIndex < 0
                      ? (days.first.date.compareTo(today) > 0 ? 0 : 1)
                      : todayIndex / 6,
                  color: hud.accent,
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < days.length; i++)
                    SizedBox(
                      width: cell,
                      child: _NodeCell(
                        plan: days[i],
                        index: i,
                        isToday: days[i].date == today,
                        selected: selected == days[i].date,
                        onTap: onSelect == null
                            ? null
                            : () => onSelect!(days[i].date),
                        showTitle: showTitles,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    return SizedBox(
      height: 2,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Container(height: 2, color: hud.hairline.withValues(alpha: 0.14)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: reduced ? Duration.zero : AppMotion.data,
              curve: AppMotion.emphasizedDecelerate,
              builder: (context, v, _) => Container(
                width: box.maxWidth * v,
                height: 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color.withValues(alpha: 0.25), color],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.6 * hud.glowStrength),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeCell extends StatelessWidget {
  const _NodeCell({
    required this.plan,
    required this.index,
    required this.isToday,
    required this.selected,
    required this.onTap,
    required this.showTitle,
  });

  final PlanDay plan;
  final int index;
  final bool isToday;
  final bool selected;
  final VoidCallback? onTap;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = sessionColor(plan.day.kind);
    final state = plan.state;
    final date = LocalDates.parse(plan.date);
    final labelColor = isToday || selected ? hud.accentInk : hud.textMuted;
    final node = _Node(
      color: c,
      state: state,
      isToday: isToday,
      icon: sessionIcon(plan.day.kind),
      selected: selected,
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 18,
          child: FittedBox(
            child: Text(
              '${weekdayLetters[index]} ${date.day}',
              style: hud.label(size: 11, color: labelColor),
            ),
          ),
        ),
        node,
        if (showTitle) ...[
          const SizedBox(height: 5),
          SizedBox(
            height: 16,
            child: FittedBox(
              child: Text(
                shortSessionTitle(plan.day.title),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: state == DayState.done || isToday || selected
                      ? hud.text
                      : hud.textMuted,
                ),
              ),
            ),
          ),
        ],
      ],
    );
    final label =
        '${weekdayShort[index]} ${plan.day.title}: ${switch (state) {
          DayState.done => 'done',
          DayState.today => 'today',
          DayState.missed => 'missed',
          DayState.untracked => 'not tracked',
          DayState.upcoming => 'upcoming',
        }}';
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.9,
        child: content,
      ),
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.color,
    required this.state,
    required this.isToday,
    required this.icon,
    required this.selected,
  });
  final Color color;
  final DayState state;
  final bool isToday;
  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    const size = 34.0;
    final done = state == DayState.done;
    final today = isToday && !done;
    final missed = state == DayState.missed;
    final ring = done
        ? color
        : today
        ? hud.accent
        : missed
        ? AppColors.warning.withValues(alpha: 0.7)
        : hud.hairline.withValues(alpha: 0.28);
    final fill = done
        ? color.withValues(alpha: hud.isDark ? 0.26 : 0.18)
        : selected
        ? hud.accent.withValues(alpha: 0.14)
        : (hud.isDark ? const Color(0xFF0A111C) : Colors.white);
    return AnimatedContainer(
      duration: AppMotion.medium,
      curve: AppMotion.standard,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(
          color: selected ? hud.accent : ring,
          width: selected || today ? 1.8 : 1.2,
        ),
        boxShadow: done || today || selected
            ? [
                BoxShadow(
                  color: (done && !selected ? color : hud.accent).withValues(
                    alpha: 0.45 * hud.glowStrength,
                  ),
                  blurRadius: 12,
                  spreadRadius: -1,
                ),
              ]
            : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Icon(
            icon,
            size: 16,
            color: done
                ? Color.lerp(color, Colors.white, hud.isDark ? 0.15 : 0)
                : today
                ? hud.accent
                : (missed ? AppColors.warning : hud.textMuted).withValues(
                    alpha: state == DayState.upcoming ? 0.7 : 0.9,
                  ),
          ),
          if (done)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.success,
                  border: Border.all(
                    color: hud.isDark ? AppColors.darkBg : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.check,
                  size: 9,
                  color: Color(0xFF02140A),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Six-segment mesocycle bar: weeks of the current block, the deload week
/// (every [TrainingProgram.deloadEvery]th) drawn amber.
class CycleBar extends StatelessWidget {
  const CycleBar({super.key, required this.program, required this.week});
  final TrainingProgram program;
  final int week;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final n = math.max(1, program.deloadEvery);
    final pos = (week - 1) % n; // 0-based position in block
    final block = (week - 1) ~/ n + 1;
    return Semantics(
      label:
          'Block $block, week ${pos + 1} of $n. '
          '${program.isDeloadWeek(week) ? 'Deload week.' : 'Deload in ${n - 1 - pos} weeks.'}',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: AnimatedContainer(
                duration: AppMotion.medium,
                height: 5,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: i == n - 1
                      ? AppColors.warning.withValues(
                          alpha: i <= pos ? 0.95 : 0.22,
                        )
                      : i < pos
                      ? hud.accent.withValues(alpha: 0.55)
                      : i == pos
                      ? hud.accent
                      : hud.hairline.withValues(alpha: 0.14),
                  boxShadow: i == pos
                      ? [
                          BoxShadow(
                            color: (i == n - 1 ? AppColors.warning : hud.accent)
                                .withValues(alpha: 0.6 * hud.glowStrength),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
