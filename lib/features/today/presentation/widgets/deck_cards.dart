import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/paths.dart';
import '../../../../core/contracts/calendar_reader.dart';
import '../../../../core/domain/provenance.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../assistant/application/providers.dart';
import '../../../life/application/habit_providers.dart';
import '../../../life/data/habit_repository.dart';
import '../../../life/domain/habit_engine.dart' show StreakUnit;
import '../../../life/domain/habit_models.dart';
import '../../../planning/application/planning_providers.dart';
import '../../../planning/data/planning_repository.dart';
import '../../../planning/domain/countdown.dart';
import '../../../planning/domain/task_rules.dart';
import '../../../planning/presentation/widgets/review_sheets.dart';
import '../../data/today_repository.dart';
import 'deck.dart';
import 'quick_actions.dart';

// ───────────────────────────────────────────────────────────── Competition

/// Gold competition module: countdown when set, otherwise a compact CTA.
class CompetitionModule extends StatelessWidget {
  const CompetitionModule({super.key, required this.view, this.name});
  final CompetitionView? view;

  /// Display name for the show-day line.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final gold = goldInk(context);
    final v = view;
    if (v == null) {
      return Semantics(
        button: true,
        label: 'Set your competition date',
        excludeSemantics: true,
        onTap: () => context.push(AppPaths.competition),
        child: AppCard(
          accent: AppColors.gold,
          onTap: () => context.push(AppPaths.competition),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md + 2,
          ),
          child: Row(
            children: [
              const GlowIcon(
                Icons.emoji_events_outlined,
                color: AppColors.gold,
                size: 20,
                framed: true,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Set your competition date', style: t.titleSmall),
                    Text(
                      'No date yet is fine. Add one for a countdown, prep '
                      'phases and a checklist.',
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: hud.textMuted),
            ],
          ),
        ),
      );
    }
    final c = v.countdown;
    final comp = v.competition;
    final (big, unit, line) = switch (c.phase) {
      CountdownPhase.upcoming => (
        '${c.daysRemaining}',
        c.daysRemaining == 1 ? 'DAY TO GO' : 'DAYS TO GO',
        c.weeksAndDaysLabel,
      ),
      CountdownPhase.today => (
        '0',
        'SHOW DAY',
        name == null ? 'Show day. Good luck.' : 'Show day. Good luck, $name.',
      ),
      CountdownPhase.past => (
        '${c.daysSince}',
        c.daysSince == 1 ? 'DAY SINCE' : 'DAYS SINCE',
        'Recover well. Reverse diet with care.',
      ),
    };
    final eventDate = DateTime(
      c.eventDate.year,
      c.eventDate.month,
      c.eventDate.day,
    );
    return AppCard(
      accent: AppColors.gold,
      glow: c.phase == CountdownPhase.today,
      onTap: () => context.push(AppPaths.competition),
      semanticLabel: '${c.headline(comp.name)}. Open competition prep.',
      child: Row(
        children: [
          Hero(
            tag: 'competition-ring-${comp.id}',
            child: ProgressRing(
              progress: c.progress ?? 0,
              color: AppColors.gold,
              size: 72,
              stroke: 6,
              celebrate: false,
              center: Text(
                c.progress == null ? '—' : '${(c.progress! * 100).round()}%',
                style: hud.number(size: 15, color: gold),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comp.name.toUpperCase(),
                  style: hud.label(size: 10.5, color: gold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    AnimatedTicker(big, style: hud.number(size: 34)),
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Text(
                        unit,
                        style: hud.label(size: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Text(
                  '$line · ${DateFormat('d MMM').format(eventDate)}'
                  '${comp.division != null ? ' · ${comp.division}' : ''}',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Agenda

class AgendaCard extends StatelessWidget {
  const AgendaCard({super.key, required this.calendar, required this.now});
  final AsyncValue<CalendarReadResult> calendar;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final r = calendar.value;
    final Widget body;
    String telemetry = '';
    if (calendar.isLoading && !calendar.hasValue) {
      body = const ScanlineLoader(lines: 2);
    } else if (calendar.hasError && r == null) {
      body = const DeckHint(
        icon: Icons.cloud_off,
        text: 'Calendar could not be loaded right now.',
      );
    } else if (r == null || !r.connected) {
      telemetry = 'OFFLINE';
      body = DeckHint(
        icon: Icons.link_off,
        text: 'Google Calendar is not connected.',
        actionLabel: 'Connect',
        onAction: () => context.push(AppPaths.integrations),
      );
    } else if (r.error != null) {
      telemetry = 'ERROR';
      body = const DeckHint(
        icon: Icons.cloud_off,
        text: 'Calendar could not be loaded right now.',
      );
    } else {
      final events = [...r.events]..sort((a, b) => a.start.compareTo(b.start));
      final allDay = events.where((e) => e.allDay).toList();
      final upcoming = events
          .where((e) => !e.allDay && e.end.isAfter(now))
          .toList();
      telemetry = '${upcoming.length} AHEAD';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in allDay.take(2))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                'All day · ${e.title}',
                style: t.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (upcoming.isEmpty)
            Text(
              'No more events today. The rest of the day is yours.',
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
          for (final e in upcoming.take(3))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      e.start.isBefore(now) ? 'NOW' : Fmt.time(e.start),
                      style: hud.mono(size: 11, color: hud.accentInk),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      e.title,
                      style: t.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (upcoming.length > 3)
            Text(
              '+${upcoming.length - 3} more',
              style: t.labelSmall?.copyWith(color: hud.textMuted),
            ),
          if (r.fetchedAt != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: SourceBadge(
                origin: DataOrigin.googleCalendar,
                asOf: r.fetchedAt,
                now: now,
              ),
            ),
          ],
        ],
      );
    }
    return AppCard(
      onTap: () => context.push(AppPaths.planner),
      semanticLabel: 'Agenda. Open the day planner.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: Icons.event_outlined,
            label: 'AGENDA',
            chevron: true,
            trailing: telemetry.isEmpty ? null : DeckTelemetry(telemetry),
          ),
          const SizedBox(height: AppSpacing.md),
          body,
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Inbox

/// Messaging-assistant drafts that wait for approval.
class InboxTeaser extends ConsumerWidget {
  const InboxTeaser({super.key});

  static const _awaiting = {'draft', 'pending_approval'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final drafts = ref.watch(openDraftsProvider);
    final n = drafts.value?.where((d) => _awaiting.contains(d.status)).length;
    final text = n == null
        ? 'Checking the assistant inbox…'
        : n == 0
        ? 'Inbox clear. No replies awaiting approval.'
        : '$n repl${n == 1 ? 'y' : 'ies'} drafted and awaiting your approval.';
    return AppCard(
      onTap: () => context.push(AppPaths.assistant),
      semanticLabel: '$text Open the assistant.',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          GlowIcon(
            Icons.forum_outlined,
            size: 18,
            color: (n ?? 0) > 0 ? hud.accent : hud.textMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ASSISTANT INBOX', style: hud.label(size: 10.5)),
                const SizedBox(height: 2),
                Text(text, style: t.bodyMedium),
              ],
            ),
          ),
          if ((n ?? 0) > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: hud.accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.xs),
                border: Border.all(color: hud.accent.withValues(alpha: 0.5)),
              ),
              child: Text('$n', style: hud.number(size: 15)),
            ),
          Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Habits

class HabitsCard extends ConsumerWidget {
  const HabitsCard({super.key});

  Future<void> _toggle(WidgetRef ref, HabitBoard board, HabitView h) async {
    final repo = ref.read(habitRepositoryProvider);
    final mark = h.todayMark;
    if (mark != null && mark.auto) return;
    if (mark == null) {
      await repo.setStatus(h.id, board.today, HabitStatus.done);
      if (board.remainingToday <= 1) {
        Haptics.goalReached();
      } else {
        Haptics.success();
      }
    } else {
      Haptics.selection();
      await repo.clearStatus(h.id, board.today);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final async = ref.watch(habitBoardProvider);
    final board = async.value;
    Widget body;
    String? telemetry;
    if (board == null) {
      body = async.hasError
          ? const DeckHint(text: 'Habits could not be loaded.')
          : const ScanlineLoader(lines: 1);
    } else if (board.habits.isEmpty) {
      body = DeckHint(
        text: 'No habits set up',
        actionLabel: 'Set up',
        onAction: () => context.push(AppPaths.habits),
      );
    } else if (board.dueToday.isEmpty) {
      body = const DeckHint(text: 'Nothing scheduled today.');
    } else {
      telemetry = '${board.doneToday}/${board.dueToday.length} DONE';
      body = Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final h in board.dueToday)
            _HabitChip(habit: h, onTap: () => _toggle(ref, board, h)),
        ],
      );
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: Icons.check_circle_outline,
            label: 'HABITS',
            color: AppColors.habit,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (telemetry != null) DeckTelemetry(telemetry),
                const SizedBox(width: AppSpacing.sm),
                PressableScale(
                  onTap: () => context.push(AppPaths.habits),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      'BOARD ›',
                      style: hud.mono(size: 10, color: hud.accentInk),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          body,
        ],
      ),
    );
  }
}

class _HabitChip extends StatelessWidget {
  const _HabitChip({required this.habit, required this.onTap});
  final HabitView habit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final mark = habit.todayMark;
    final done = mark?.isDone ?? false;
    final skipped = mark?.isSkipped ?? false;
    const c = AppColors.habit;
    return Semantics(
      button: true,
      toggled: done,
      label:
          '${habit.name}${done
              ? ', done'
              : skipped
              ? ', skipped'
              : ''}'
          '${mark?.auto == true ? ', completed automatically' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.none,
        pressedScale: 0.92,
        child: AnimatedContainer(
          duration: AppMotion.medium,
          curve: AppMotion.emphasizedDecelerate,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            color: c.withValues(alpha: done ? 0.18 : 0.05),
            border: Border.all(color: c.withValues(alpha: done ? 0.7 : 0.22)),
            boxShadow: done
                ? [
                    BoxShadow(
                      color: c.withValues(alpha: 0.25 * hud.glowStrength),
                      blurRadius: 12,
                      spreadRadius: -2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.short,
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(
                  mark?.auto == true
                      ? Icons.bolt
                      : done
                      ? Icons.check_circle
                      : skipped
                      ? Icons.remove_circle_outline
                      : Icons.radio_button_unchecked,
                  key: ValueKey('$done$skipped'),
                  size: 16,
                  color: done ? c : hud.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  habit.name,
                  style: t.labelLarge?.copyWith(
                    color: skipped ? hud.textMuted : null,
                    decoration: skipped ? TextDecoration.lineThrough : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (habit.streak.current > 1) ...[
                const SizedBox(width: 6),
                Text(
                  '${habit.streak.current}'
                  '${habit.streak.unit == StreakUnit.weeks ? 'w' : 'd'}',
                  style: hud.mono(size: 10, color: goldInk(context)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Priorities

class PrioritiesCard extends ConsumerWidget {
  const PrioritiesCard({super.key, required this.snapshot});
  final TodaySnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = snapshot;
    final repo = ref.read(planningRepositoryProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: Icons.flag_outlined,
            label: 'TOP 3 PRIORITIES',
            trailing: s.taskCount > 0
                ? DeckTelemetry('${s.tasksDone}/${s.taskCount} DONE')
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (s.topTasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                'No priorities set for today.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.hud.textMuted),
              ),
            ),
          for (final task in s.topTasks)
            _TaskRow(
              task: task,
              onToggle: () async {
                final done = !task.done;
                await repo.setTaskDone(task.id, done);
                if (done) {
                  final remaining = s.topTasks.where((t) => !t.done).length;
                  remaining <= 1 ? Haptics.goalReached() : Haptics.success();
                } else {
                  Haptics.selection();
                }
              },
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: HudButton.secondary(
                  label: s.topTasks.isEmpty ? 'Add priorities' : 'Add',
                  icon: Icons.add,
                  compact: true,
                  onPressed: () => showAddPrioritySheet(context, date: s.date),
                ),
              ),

              Flexible(
                child: HudButton.ghost(
                  label: 'Open planner',
                  compact: true,
                  onPressed: () => context.push(AppPaths.planner),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onToggle});
  final TaskItem task;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    // Priority is rank, not alarm: red stays reserved for alerts.
    final pColor = switch (task.priority) {
      1 => hud.accentInk,
      2 => hud.text,
      _ => hud.textMuted,
    };
    return Semantics(
      checked: task.done,
      button: true,
      label: '${task.title}, priority ${task.priority}',
      excludeSemantics: true,
      onTap: onToggle,
      child: PressableScale(
        onTap: onToggle,
        haptic: PressHaptic.none,
        pressedScale: 0.98,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AppMotion.medium,
                curve: AppMotion.emphasizedDecelerate,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: task.done ? AppColors.gold : Colors.transparent,
                  border: Border.all(
                    color: task.done
                        ? AppColors.gold
                        : hud.textMuted.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  boxShadow: task.done
                      ? AppGlows.soft(
                          AppColors.gold,
                          strength: hud.glowStrength,
                        )
                      : null,
                ),
                child: task.done
                    ? const Icon(
                        Icons.check,
                        size: 14,
                        color: Color(0xFF1F1400),
                      )
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.short,
                      style: t.bodyLarge!.copyWith(
                        decoration: task.done
                            ? TextDecoration.lineThrough
                            : null,
                        color: task.done ? hud.textMuted : hud.text,
                      ),
                      child: Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (task.project != null)
                      Text(
                        task.project!,
                        style: t.labelSmall?.copyWith(color: hud.textMuted),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'P${task.priority}',
                style: hud
                    .mono(size: 10.5, color: pColor)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fast "add a priority" sheet (title + P1/P2/P3).
Future<void> showAddPrioritySheet(
  BuildContext context, {
  required String date,
}) => showHudBottomSheet<void>(
  context,
  title: 'Add priority',
  builder: (_) => _AddPriority(date: date),
);

class _AddPriority extends ConsumerStatefulWidget {
  const _AddPriority({required this.date});
  final String date;

  @override
  ConsumerState<_AddPriority> createState() => _AddPriorityState();
}

class _AddPriorityState extends ConsumerState<_AddPriority> {
  final _title = TextEditingController();
  int _priority = 1;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final nav = Navigator.of(context);
    await ref
        .read(planningRepositoryProvider)
        .addTask(title: title, date: widget.date, priority: _priority);
    Haptics.success();
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'What would make today a win?',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: AppSpacing.lg),
        SegmentedHud<int>(
          segments: const [
            HudSegment(value: 1, label: 'P1'),
            HudSegment(value: 2, label: 'P2'),
            HudSegment(value: 3, label: 'P3'),
          ],
          value: _priority,
          onChanged: (v) => setState(() => _priority = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: 'Add to today',
          icon: Icons.add_task,
          expand: true,
          onPressed: _title.text.trim().isEmpty ? null : _save,
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────── Review

/// Mood, journal and the end-of-day review. Leads the deck in the evening.
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.snapshot, required this.evening});
  final TodaySnapshot snapshot;
  final bool evening;

  static const moodLabels = ['Awful', 'Low', 'Okay', 'Good', 'Great'];

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final mood = snapshot.moodToday;
    Widget row({
      required IconData icon,
      required Color color,
      required String label,
      required String value,
      required bool done,
      required VoidCallback onTap,
    }) => Semantics(
      button: true,
      label: '$label: $value',
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        pressedScale: 0.98,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              GlowIcon(icon, size: 18, color: color, framed: true),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label.toUpperCase(), style: hud.label(size: 10)),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: done ? hud.text : hud.textMuted),
                    ),
                  ],
                ),
              ),
              if (done)
                const StatusDot(color: AppColors.success)
              else
                Icon(Icons.chevron_right, color: hud.textMuted),
            ],
          ),
        ),
      ),
    );
    return AppCard(
      accent: evening ? AppColors.sleep : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: evening ? Icons.nightlight_outlined : Icons.favorite_border,
            label: evening ? 'EVENING REVIEW' : 'CHECK-INS',
            color: evening ? AppColors.sleep : AppColors.mood,
          ),
          const SizedBox(height: AppSpacing.sm),
          row(
            icon: Icons.mood,
            color: AppColors.mood,
            label: 'Mood',
            value: mood == null
                ? 'Not checked in yet'
                : '${moodLabels[(mood.mood - 1).clamp(0, 4)]} · '
                      '${mood.mood}/5 at ${Fmt.time(mood.recordedAt)}',
            done: mood != null,
            onTap: () => showQuickMoodSheet(context),
          ),
          row(
            icon: Icons.menu_book_outlined,
            color: AppColors.sleep,
            label: 'Journal',
            value: snapshot.journalToday
                ? 'Written today'
                : 'No entry yet today',
            done: snapshot.journalToday,
            onTap: () => context.push(AppPaths.journal),
          ),
          if (evening) ...[
            const SizedBox(height: AppSpacing.sm),
            HudButton.secondary(
              label: 'End-of-day review',
              icon: Icons.nightlight_outlined,
              expand: true,
              compact: true,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                useSafeArea: true,
                builder: (_) => EndOfDayReviewSheet(date: snapshot.date),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Vitals

class VitalsCard extends StatelessWidget {
  const VitalsCard({super.key, required this.snapshot});
  final TodaySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final hud = context.hud;
    final sleep = s.sleep;
    final hr = s.latestHeartRate;
    final runs = s.weekRuns;
    final w = s.latestWorkout;
    final tiles = [
      _Vital(
        label: 'SLEEP',
        icon: Icons.bedtime_outlined,
        color: AppColors.sleep,
        value: sleep == null
            ? null
            : '${sleep.value.round() ~/ 60}h ${sleep.value.round() % 60}m',
        sub: sleep == null
            ? 'No sleep data'
            : DataOrigin.fromKey(sleep.origin).label,
        onTap: () => context.push(AppPaths.healthOverview),
      ),
      _Vital(
        label: 'HEART RATE',
        icon: Icons.favorite_outline,
        color: AppColors.heart,
        value: hr == null ? null : '${hr.value.round()} bpm',
        sub: hr == null ? 'No heart-rate data' : 'at ${Fmt.time(hr.endAt)}',
        onTap: () => context.push(AppPaths.healthOverview),
      ),
      _Vital(
        label: 'RUNS · WEEK',
        icon: Icons.directions_run,
        color: AppColors.running,
        value: runs.count == 0 ? null : Fmt.km(runs.distanceM),
        sub: runs.count == 0
            ? 'No runs this week'
            : '${runs.count} run${runs.count == 1 ? '' : 's'}',
        onTap: () => context.push(AppPaths.running),
      ),
      _Vital(
        label: 'LAST WORKOUT',
        icon: Icons.fitness_center,
        color: AppColors.strength,
        value: w?.title,
        sub: w == null
            ? 'No workouts recorded yet'
            : [
                Fmt.weekdayDayMonth(w.startAt),
                if (s.latestWorkoutExercises > 0)
                  '${s.latestWorkoutExercises} exercise'
                      '${s.latestWorkoutExercises == 1 ? '' : 's'}',
              ].join(' · '),
        onTap: w == null
            ? () => context.push(AppPaths.strength)
            : () => context.push(
                AppPaths.workoutDetail.replaceFirst(':id', w.id),
              ),
      ),
    ];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeckLabel(
            icon: Icons.monitor_heart_outlined,
            label: 'VITALS',
            color: AppColors.heart,
            trailing: PressableScale(
              onTap: () => context.push(AppPaths.reports),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  'REPORTS ›',
                  style: hud.mono(size: 10, color: hud.accentInk),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, box) {
              final w = (box.maxWidth - AppSpacing.md) / 2;
              return Wrap(
                spacing: AppSpacing.md,
                children: [for (final t in tiles) SizedBox(width: w, child: t)],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Vital extends StatelessWidget {
  const _Vital({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.sub,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final String? value;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$label: ${value ?? ''} $sub',
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        pressedScale: 0.96,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      style: hud.label(size: 9.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              if (value == null)
                Text('—', style: hud.number(size: 20, color: hud.textMuted))
              else if (value!.contains(RegExp('[A-Za-z]{3,}')))
                Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleMedium?.copyWith(
                    fontFamily: AppFonts.display,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                AnimatedTicker(
                  value!,
                  style: t.titleMedium?.copyWith(
                    fontFamily: AppFonts.display,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              Text(
                sub,
                style: t.labelSmall?.copyWith(color: hud.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
