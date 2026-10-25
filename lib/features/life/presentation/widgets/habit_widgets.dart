import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/habit_providers.dart';
import '../../data/habit_repository.dart';
import '../../domain/habit_engine.dart';
import '../../domain/habit_models.dart';
import '../../domain/suggested_habits.dart';
import 'life_widgets.dart';

// ── Streak milestones ───────────────────────────────────────────────────────

const _dayMilestones = [3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 250, 300, 365];
const _weekMilestones = [2, 4, 8, 12, 16, 26, 52];

/// True when the current streak sits exactly on a celebrated milestone.
bool isStreakMilestone(StreakResult s) =>
    (s.unit == StreakUnit.weeks ? _weekMilestones : _dayMilestones).contains(
      s.current,
    );

/// A "hot" streak earns gold (a week of days, or a month of weeks).
bool isHotStreak(StreakResult s) =>
    s.current >= (s.unit == StreakUnit.weeks ? 4 : 7);

String streakShort(StreakResult s) =>
    '${s.current}${s.unit == StreakUnit.weeks ? 'w' : 'd'}';

// ── Actions ─────────────────────────────────────────────────────────────────

/// Shared habit mutations with consistent haptics and honest messages.
abstract final class HabitActions {
  /// Sets (or clears, with null) today's status for [view]. Skips show an
  /// undo snackbar ("No penalty").
  static Future<void> setToday(
    BuildContext context,
    WidgetRef ref,
    HabitView view,
    HabitStatus? status,
  ) async {
    final repo = ref.read(habitRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final today = LocalDates.key(ref.read(clockProvider).now());
    final previous = view.marks[today];
    switch (status) {
      case HabitStatus.done:
        Haptics.success();
      case HabitStatus.skipped:
        // Long-press already fired a medium tick; keep this one soft.
        Haptics.light();
      case null:
        Haptics.light();
    }
    if (status == null) {
      await repo.clearStatus(view.id, today);
    } else {
      await repo.setStatus(view.id, today, status);
    }
    if (status == HabitStatus.skipped) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('${view.name} skipped today. No penalty.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              if (previous == null || previous.auto) {
                await repo.clearStatus(view.id, today);
              } else {
                await repo.setStatus(view.id, today, previous.status);
              }
            },
          ),
        ),
      );
    }
  }

  /// Tap behaviour: open → done, done/skipped → cleared. Automatic
  /// completions explain themselves instead of toggling.
  static Future<void> toggle(
    BuildContext context,
    WidgetRef ref,
    HabitView view,
  ) async {
    final mark = view.todayMark;
    if (mark?.auto ?? false) {
      Haptics.light();
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Completed automatically from your logged data. '
              'Use the menu if you want to mark it differently.',
            ),
          ),
        );
      return;
    }
    await setToday(context, ref, view, mark == null ? HabitStatus.done : null);
  }
}

// ── Check node ──────────────────────────────────────────────────────────────

enum HabitNodeState { open, done, auto, skipped }

HabitNodeState nodeStateOf(DayMark? m) => m == null
    ? HabitNodeState.open
    : m.isSkipped
    ? HabitNodeState.skipped
    : m.auto
    ? HabitNodeState.auto
    : HabitNodeState.done;

/// The tactile completion "reactor node": an open ring that floods with
/// light and draws a check when done; dashed with a dash when skipped; a
/// half-lit ring with a bolt when completed automatically.
class HabitCheckNode extends StatelessWidget {
  const HabitCheckNode({
    super.key,
    required this.state,
    this.size = 44,
    this.color = AppColors.habit,
  });

  final HabitNodeState state;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    final lit = state == HabitNodeState.done || state == HabitNodeState.auto;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: lit ? 1 : 0),
        duration: reduced ? Duration.zero : const Duration(milliseconds: 520),
        curve: SpringCurve(AppMotion.bouncy),
        builder: (context, t, _) => CustomPaint(
          painter: _NodePainter(t: t, state: state, color: color, hud: hud),
        ),
      ),
    );
  }
}

class _NodePainter extends CustomPainter {
  _NodePainter({
    required this.t,
    required this.state,
    required this.color,
    required this.hud,
  });
  final double t;
  final HabitNodeState state;
  final Color color;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final r = s * 0.42;
    final stroke = math.max(1.5, s * 0.055);
    final auto = state == HabitNodeState.auto;
    final skipped = state == HabitNodeState.skipped;
    final ft = t.clamp(0.0, 1.2);

    if (skipped) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.8
        ..strokeCap = StrokeCap.round
        ..color = hud.textMuted.withValues(alpha: 0.7);
      for (var i = 0; i < 12; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          i / 12 * math.pi * 2,
          math.pi * 2 / 12 * 0.55,
          false,
          p,
        );
      }
      canvas.drawLine(
        c + Offset(-r * 0.38, 0),
        c + Offset(r * 0.38, 0),
        p..strokeWidth = stroke,
      );
      return;
    }

    // Track ring.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.8
        ..color = Color.lerp(
          hud.hairline.withValues(alpha: hud.isDark ? 0.35 : 0.45),
          color,
          ft.clamp(0.0, 1.0),
        )!,
    );
    if (ft <= 0.001) return;

    // Bloom + flood fill (grows from the centre, overshooting slightly).
    canvas.drawCircle(
      c,
      r * 1.25,
      Paint()
        ..color = color.withValues(
          alpha: (auto ? 0.16 : 0.32) * hud.glowStrength * ft.clamp(0.0, 1.0),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.14),
    );
    final fillR = r * ft;
    final fillRect = Rect.fromCircle(center: c, radius: fillR);
    canvas.drawCircle(
      c,
      fillR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [
            Color.lerp(
              color,
              Colors.white,
              0.35,
            )!.withValues(alpha: auto ? 0.55 : 1),
            color.withValues(alpha: auto ? 0.4 : 0.9),
          ],
        ).createShader(fillRect),
    );

    final ink = const Color(0xFF04131A);
    if (auto) {
      // Bolt glyph.
      final b = r * 0.55;
      final path = Path()
        ..moveTo(c.dx + b * 0.15, c.dy - b)
        ..lineTo(c.dx - b * 0.5, c.dy + b * 0.12)
        ..lineTo(c.dx - b * 0.02, c.dy + b * 0.12)
        ..lineTo(c.dx - b * 0.15, c.dy + b)
        ..lineTo(c.dx + b * 0.5, c.dy - b * 0.12)
        ..lineTo(c.dx + b * 0.02, c.dy - b * 0.12)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = (hud.isDark ? Colors.white : ink).withValues(
            alpha: ft.clamp(0.0, 1.0),
          ),
      );
      return;
    }

    // Check mark, drawn in after the flood passes half-way.
    final ct = ((ft - 0.35) / 0.65).clamp(0.0, 1.0);
    if (ct <= 0) return;
    final a = c + Offset(-r * 0.42, r * 0.02);
    final b = c + Offset(-r * 0.1, r * 0.34);
    final d = c + Offset(r * 0.46, -r * 0.3);
    final path = Path()..moveTo(a.dx, a.dy);
    final l1 = (b - a).distance;
    final l2 = (d - b).distance;
    final len = (l1 + l2) * ct;
    if (len <= l1) {
      final p = a + (b - a) * (len / l1);
      path.lineTo(p.dx, p.dy);
    } else {
      path.lineTo(b.dx, b.dy);
      final p = b + (d - b) * ((len - l1) / l2);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 1.25
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = ink,
    );
  }

  @override
  bool shouldRepaint(_NodePainter old) =>
      old.t != t || old.state != state || old.color != color || old.hud != hud;
}

// ── Streak flame ────────────────────────────────────────────────────────────

/// Flame + streak count. Gold with a soft glow once the streak is "hot".
class StreakFlame extends StatelessWidget {
  const StreakFlame({super.key, required this.streak, this.size = 14});
  final StreakResult streak;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final hot = isHotStreak(streak);
    final c = hot ? AppColors.gold : hud.textMuted;
    return Semantics(
      label: '${streak.format(streak.current)} streak',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hot
                ? Icons.local_fire_department_rounded
                : Icons.local_fire_department_outlined,
            size: size,
            color: c,
            shadows: hot ? AppGlows.text(c, strength: hud.glowStrength) : null,
          ),
          const SizedBox(width: 2),
          Text(
            streakShort(streak),
            style: hud
                .mono(
                  size: size * 0.8,
                  color: hot && !hud.isDark ? hud.text : c,
                )
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ── Celebration wrapper ─────────────────────────────────────────────────────

/// Wraps a habit control: when the habit becomes done today and its streak
/// lands on a milestone, plays a burst + goal haptic and floats a
/// "7-DAY STREAK" tag — once per habit per day.
class HabitMilestoneCelebration extends StatefulWidget {
  const HabitMilestoneCelebration({
    super.key,
    required this.view,
    required this.today,
    required this.child,
  });

  final HabitView view;
  final String today;
  final Widget child;

  @override
  State<HabitMilestoneCelebration> createState() =>
      _HabitMilestoneCelebrationState();
}

class _HabitMilestoneCelebrationState extends State<HabitMilestoneCelebration>
    with SingleTickerProviderStateMixin {
  final _burst = CelebrationController();
  late final AnimationController _tag = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  String? _tagText;

  @override
  void didUpdateWidget(HabitMilestoneCelebration old) {
    super.didUpdateWidget(old);
    final was = old.view.todayMark?.isDone ?? false;
    final now = widget.view.todayMark?.isDone ?? false;
    if (!was &&
        now &&
        isStreakMilestone(widget.view.streak) &&
        LifeCelebrations.claim('streak:${widget.view.id}', widget.today)) {
      final s = widget.view.streak;
      _tagText =
          '${s.current}-${s.unit == StreakUnit.weeks ? 'WEEK' : 'DAY'} STREAK';
      Haptics.goalReached();
      if (!AppMotion.reduced(context)) {
        _burst.fire();
        _tag.forward(from: 0);
      }
      SemanticsService.sendAnnouncement(
        View.of(context),
        '${widget.view.name}: ${s.format(s.current)} streak',
        Directionality.of(context),
      );
    }
  }

  @override
  void dispose() {
    _burst.dispose();
    _tag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CelebrationBurst(
          controller: _burst,
          color: AppColors.gold,
          particles: 18,
          spread: 0.8,
          child: widget.child,
        ),
        Positioned(
          left: 0,
          right: 0,
          top: -6,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _tag,
              builder: (context, _) {
                final v = _tag.value;
                if (v == 0 || v == 1 || _tagText == null) {
                  return const SizedBox.shrink();
                }
                final rise = Curves.easeOutCubic.transform(v);
                final fade = v < 0.15
                    ? v / 0.15
                    : (1 - (v - 0.6) / 0.4).clamp(0.0, 1.0);
                return Transform.translate(
                  offset: Offset(0, -28 * rise),
                  child: Opacity(
                    opacity: fade,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.gold.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                          border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Text(
                          _tagText!,
                          style: hud.label(
                            size: 11,
                            color: hud.isDark ? AppColors.gold : hud.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ── Hub chip ────────────────────────────────────────────────────────────────

/// Today's habit as a tactile pill: tap = done / undo, long-press = skip.
class HabitChip extends ConsumerWidget {
  const HabitChip({
    super.key,
    required this.view,
    required this.today,
    this.expand = false,
  });
  final HabitView view;
  final String today;

  /// Fill the row (name left, streak right) instead of hugging content.
  final bool expand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final state = nodeStateOf(view.todayMark);
    final lit = state == HabitNodeState.done || state == HabitNodeState.auto;
    final skipped = state == HabitNodeState.skipped;
    const c = AppColors.habit;
    final hint = state == HabitNodeState.open
        ? 'Tap to mark done, long press to skip'
        : state == HabitNodeState.auto
        ? 'Completed automatically'
        : 'Tap to undo';
    return HabitMilestoneCelebration(
      view: view,
      today: today,
      child: Semantics(
        button: true,
        toggled: lit,
        label:
            '${view.name}${skipped ? ', skipped' : ''}'
            '${view.streak.current > 0 ? ', ${view.streak.format(view.streak.current)} streak' : ''}',
        hint: hint,
        excludeSemantics: true,
        onLongPress: state == HabitNodeState.open
            ? () =>
                  HabitActions.setToday(context, ref, view, HabitStatus.skipped)
            : null,
        child: PressableScale(
          key: Key('habit-chip-${view.id}'),
          haptic: PressHaptic.none,
          pressedScale: 0.93,
          onTap: () => HabitActions.toggle(context, ref, view),
          onLongPress: state == HabitNodeState.open
              ? () => HabitActions.setToday(
                  context,
                  ref,
                  view,
                  HabitStatus.skipped,
                )
              : null,
          child: AnimatedContainer(
            duration: AppMotion.medium,
            curve: AppMotion.standard,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: lit
                  ? c.withValues(alpha: hud.isDark ? 0.13 : 0.16)
                  : hud.glassFill,
              border: Border.all(
                color: lit
                    ? c.withValues(alpha: 0.65)
                    : hud.hairline.withValues(alpha: skipped ? 0.12 : 0.22),
              ),
              boxShadow: lit
                  ? [
                      BoxShadow(
                        color: c.withValues(alpha: 0.22 * hud.glowStrength),
                        blurRadius: 14,
                        spreadRadius: -4,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                HabitCheckNode(state: state, size: 30),
                const SizedBox(width: 8),
                Flexible(
                  fit: expand ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    view.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge?.copyWith(
                      color: skipped ? hud.textMuted : hud.text,
                      decoration: skipped ? TextDecoration.lineThrough : null,
                      decorationColor: hud.textMuted,
                    ),
                  ),
                ),
                if (view.streak.current > 0 && !skipped) ...[
                  const SizedBox(width: 8),
                  StreakFlame(streak: view.streak, size: 13),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Seven-day strip ─────────────────────────────────────────────────────────

/// The last seven days ending today as small luminous cells.
class HabitWeekStrip extends StatelessWidget {
  const HabitWeekStrip({
    super.key,
    required this.view,
    required this.today,
    this.cell = 9,
  });
  final HabitView view;
  final String today;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    const c = AppColors.habit;
    var done = 0, skipped = 0;
    final cells = <Widget>[];
    for (var i = 6; i >= 0; i--) {
      final d = LocalDates.addDays(today, -i);
      final mark = view.marks[d];
      final before = d.compareTo(view.startDate) < 0 && mark == null;
      final scheduled = view.schedule.isScheduledDay(d);
      final isToday = i == 0;
      BoxDecoration deco;
      if (mark?.isDone ?? false) {
        done++;
        deco = BoxDecoration(
          color: c.withValues(alpha: mark!.auto ? 0.5 : 0.95),
          borderRadius: BorderRadius.circular(2.5),
          boxShadow: [
            BoxShadow(
              color: c.withValues(alpha: 0.4 * hud.glowStrength),
              blurRadius: 5,
            ),
          ],
        );
      } else if (mark?.isSkipped ?? false) {
        skipped++;
        deco = BoxDecoration(
          borderRadius: BorderRadius.circular(2.5),
          border: Border.all(color: hud.textMuted.withValues(alpha: 0.6)),
        );
      } else if (before || (!scheduled && !view.schedule.isWeekly)) {
        deco = BoxDecoration(
          color: hud.hairline.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(2.5),
        );
      } else {
        deco = BoxDecoration(
          color: hud.hairline.withValues(alpha: hud.isDark ? 0.12 : 0.2),
          borderRadius: BorderRadius.circular(2.5),
          border: isToday
              ? Border.all(color: hud.accent.withValues(alpha: 0.7))
              : null,
        );
      }
      cells.add(
        Container(
          width: cell,
          height: cell,
          margin: const EdgeInsets.only(right: 3),
          decoration: deco,
        ),
      );
    }
    return Semantics(
      label:
          'Last 7 days: $done done${skipped > 0 ? ', $skipped skipped' : ''}',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: cells),
    );
  }
}

// ── Month heatmap ───────────────────────────────────────────────────────────

/// Month grid (Mon–Sun columns): luminous done cells, dashed skips, faint
/// open days, a cyan bracket on today. Swipe horizontally to change month.
class HabitMonthHeatmap extends StatelessWidget {
  const HabitMonthHeatmap({
    super.key,
    required this.view,
    required this.month,
    required this.today,
    required this.onDayTap,
  });

  final HabitView view;
  final DateTime month;
  final String today;
  final ValueChanged<String> onDayTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    const c = AppColors.habit;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = first.weekday - 1;
    final rows = ((leading + daysInMonth) / 7).ceil();
    return LayoutBuilder(
      builder: (context, box) {
        final cellW = box.maxWidth / 7;
        final cellH = math.min(cellW, 46.0);
        Widget cellAt(int index) {
          final d = index - leading + 1;
          if (d < 1 || d > daysInMonth) {
            return SizedBox(width: cellW, height: cellH);
          }
          final key = LocalDates.key(DateTime(month.year, month.month, d));
          final mark = view.marks[key];
          final future = key.compareTo(today) > 0;
          final scheduled = view.schedule.isScheduledDay(key);
          final beforeStart = key.compareTo(view.startDate) < 0 && mark == null;
          final isToday = key == today;
          String status;
          Widget face;
          if (mark?.isDone ?? false) {
            status = mark!.auto ? 'done automatically' : 'done';
            face = DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.xs),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(
                      c,
                      Colors.white,
                      0.2,
                    )!.withValues(alpha: mark.auto ? 0.45 : 0.95),
                    c.withValues(alpha: mark.auto ? 0.3 : 0.75),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: c.withValues(
                      alpha: (mark.auto ? 0.12 : 0.28) * hud.glowStrength,
                    ),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '$d',
                  style: t.labelMedium?.copyWith(
                    color: const Color(0xFF04131A),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          } else if (mark?.isSkipped ?? false) {
            status = 'skipped';
            face = CustomPaint(
              painter: _DashedBoxPainter(hud.textMuted.withValues(alpha: 0.7)),
              child: Center(
                child: Text(
                  '$d',
                  style: t.labelMedium?.copyWith(color: hud.textMuted),
                ),
              ),
            );
          } else if (future || beforeStart || !scheduled) {
            status = future ? 'upcoming' : 'not scheduled';
            face = Center(
              child: Text(
                '$d',
                style: t.labelMedium?.copyWith(
                  color: hud.textMuted.withValues(alpha: 0.45),
                ),
              ),
            );
          } else {
            status = isToday ? 'open' : 'missed';
            face = DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.xs),
                color: hud.hairline.withValues(alpha: hud.isDark ? 0.07 : 0.12),
                border: Border.all(
                  color: hud.hairline.withValues(
                    alpha: hud.isDark ? 0.14 : 0.25,
                  ),
                ),
              ),
              child: Center(child: Text('$d', style: t.labelMedium)),
            );
          }
          if (isToday) {
            face = HudFrame(
              color: hud.accent,
              cornerLength: 6,
              strokeWidth: 1.5,
              inset: -2,
              child: face,
            );
          }
          return SizedBox(
            width: cellW,
            height: cellH,
            child: Padding(
              padding: const EdgeInsets.all(3.5),
              child: Semantics(
                button: !future,
                label:
                    '${DateFormat('d MMMM').format(LocalDates.parse(key))}, $status',
                excludeSemantics: true,
                child: PressableScale(
                  onTap: future ? null : () => onDayTap(key),
                  haptic: PressHaptic.selection,
                  pressedScale: 0.88,
                  child: face,
                ),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (final l in weekdayLetter)
                  SizedBox(
                    width: cellW,
                    child: Center(child: Text(l, style: hud.label(size: 11))),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var r = 0; r < rows; r++)
              Row(children: [for (var i = 0; i < 7; i++) cellAt(r * 7 + i)]),
          ],
        );
      },
    );
  }
}

class _DashedBoxPainter extends CustomPainter {
  _DashedBoxPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final rr = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.6),
      const Radius.circular(AppRadii.xs),
    );
    final path = Path()..addRRect(rr);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 3), p);
        d += 6;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBoxPainter old) => old.color != color;
}

/// Legend for [HabitMonthHeatmap].
class HabitHeatmapLegend extends StatelessWidget {
  const HabitHeatmapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    const c = AppColors.habit;
    Widget item(Widget swatch, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 11, child: swatch),
        const SizedBox(width: 5),
        Text(label, style: hud.label(size: 10.5)),
      ],
    );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        item(
          DecoratedBox(
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          'DONE',
        ),
        item(
          DecoratedBox(
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          'AUTO',
        ),
        item(
          CustomPaint(
            painter: _DashedBoxPainter(hud.textMuted.withValues(alpha: 0.8)),
          ),
          'SKIPPED',
        ),
        item(
          DecoratedBox(
            decoration: BoxDecoration(
              color: hud.hairline.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(2.5),
              border: Border.all(color: hud.hairline.withValues(alpha: 0.2)),
            ),
          ),
          'MISSED',
        ),
      ],
    );
  }
}

/// Swipeable month container with a header ("‹ OCTOBER 2026 ›").
class MonthSwitcher extends StatefulWidget {
  const MonthSwitcher({
    super.key,
    required this.month,
    required this.maxMonth,
    required this.onChanged,
    required this.builder,
  });

  final DateTime month;

  /// Latest month that may be shown (usually the current month).
  final DateTime maxMonth;
  final ValueChanged<DateTime> onChanged;
  final WidgetBuilder builder;

  @override
  State<MonthSwitcher> createState() => _MonthSwitcherState();
}

class _MonthSwitcherState extends State<MonthSwitcher> {
  int _dir = 0;

  bool get _canNext => !DateTime(
    widget.month.year,
    widget.month.month + 1,
  ).isAfter(widget.maxMonth);

  void _go(int delta) {
    if (delta > 0 && !_canNext) {
      Haptics.warning();
      return;
    }
    Haptics.selection();
    setState(() => _dir = delta);
    widget.onChanged(DateTime(widget.month.year, widget.month.month + delta));
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    Widget arrow(IconData icon, String tip, bool enabled, int delta) =>
        IconButton(
          tooltip: tip,
          onPressed: enabled ? () => _go(delta) : null,
          icon: Icon(icon),
        );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 250) return;
        _go(v < 0 ? 1 : -1);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              arrow(Icons.chevron_left, 'Previous month', true, -1),
              Expanded(
                child: Center(
                  child: Text(
                    DateFormat('MMMM yyyy').format(widget.month).toUpperCase(),
                    style: hud.label(size: 13, color: hud.text),
                  ),
                ),
              ),
              arrow(Icons.chevron_right, 'Next month', _canNext, 1),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          AnimatedSwitcher(
            duration: reduced ? Duration.zero : AppMotion.medium,
            switchInCurve: AppMotion.emphasizedDecelerate,
            switchOutCurve: AppMotion.emphasizedAccelerate,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            transitionBuilder: (child, a) {
              final incoming = child.key == ValueKey(widget.month);
              final dx = (incoming ? 1 : -1) * _dir * 0.18;
              return FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(
                    begin: Offset(dx, 0),
                    end: Offset.zero,
                  ).animate(a),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(widget.month),
              child: widget.builder(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-tap starter habits (templates, never fabricated history). Adds the
/// habit immediately with a success haptic.
class HabitQuickStart extends ConsumerWidget {
  const HabitQuickStart({super.key, this.count = 4});
  final int count;

  Future<void> _add(
    BuildContext context,
    WidgetRef ref,
    HabitTemplate tpl,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Haptics.success();
    await ref
        .read(habitRepositoryProvider)
        .create(
          HabitInput(
            name: tpl.name,
            category: tpl.category,
            schedule: tpl.schedule,
            autoRule: tpl.autoRule,
            reminderTimes: tpl.reminderTimes,
          ),
        );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added "${tpl.name}"')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('QUICK START · ONE TAP', style: hud.label(size: 10.5)),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final tpl in suggestedHabits.take(count))
              LifePill(
                label: tpl.name,
                icon: tpl.autoRule != null ? Icons.bolt : Icons.add,
                color: AppColors.habit,
                onTap: () => _add(context, ref, tpl),
              ),
          ],
        ),
      ],
    );
  }
}
