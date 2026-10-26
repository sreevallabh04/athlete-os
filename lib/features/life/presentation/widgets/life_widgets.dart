import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/crisis_detector.dart';
import '../../domain/habit_models.dart';

/// Calm, non-judgemental support card shown when a note clearly expresses
/// severe distress. Never blocks saving and makes no diagnosis.
///
/// Deliberately soft: a slow-breathing cool glow (never red, never
/// flashing), plain words and one clear next step.
class SupportCard extends StatelessWidget {
  const SupportCard({super.key});

  static const calm = Color(0xFF9FB3C4);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Semantics(
      container: true,
      label: 'Support information',
      child: GlassPanel(
        accent: calm,
        borderStrength: 1.2,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const BreathingDot(color: calm),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'You don\'t have to carry this alone',
                    style: t.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'It sounds like things may be really hard right now. Consider '
              'reaching out to someone you trust and telling them how you '
              'feel. If you are in immediate danger, please contact your '
              'local emergency services now.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You can find a free, confidential crisis line in your country '
              'at findahelpline.com.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.lg),
            HudButton.secondary(
              label: 'Find a helpline',
              icon: Icons.open_in_new,
              onPressed: () => launchUrl(
                Uri.parse(crisisHelplineUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.lock_outline, size: 13, color: hud.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Your entry is still saved, privately on this device.',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A soft dot that breathes on a slow 8-second cycle (4 s in, 4 s out) —
/// paced like calm breathing, never a blink.
class BreathingDot extends StatefulWidget {
  const BreathingDot({super.key, required this.color, this.size = 28});
  final Color color;
  final double size;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context) || RuntimeEnv.isFlutterTest) {
      _c.stop();
      _c.value = 0.6;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = context.hud.glowStrength;
    final s = widget.size;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = Curves.easeInOut.transform(_c.value);
          return SizedBox.square(
            dimension: s,
            child: Center(
              child: Container(
                width: s * (0.42 + 0.28 * v),
                height: s * (0.42 + 0.28 * v),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 + 0.25 * v),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(
                        alpha: (0.25 + 0.3 * v) * glow,
                      ),
                      blurRadius: s * (0.35 + 0.3 * v),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

IconData moodIcon(int mood) => switch (mood) {
  1 => Icons.sentiment_very_dissatisfied,
  2 => Icons.sentiment_dissatisfied,
  3 => Icons.sentiment_neutral,
  4 => Icons.sentiment_satisfied,
  _ => Icons.sentiment_very_satisfied,
};

/// Ash → champagne → gold: luminance rises with mood, and low moods are
/// never shown in alarming red.
Color moodColor(int mood) => switch (mood) {
  1 => const Color(0xFF7D7770),
  2 => const Color(0xFFA39C92),
  3 => const Color(0xFFC9BBA8),
  4 => const Color(0xFFE9B04A),
  _ => AppColors.mood,
};

/// Continuous version of [moodColor] for fractional means (1.0–5.0).
Color moodColorAt(double mood) {
  final m = mood.clamp(1.0, 5.0);
  final lo = m.floor();
  final hi = m.ceil();
  if (lo == hi) return moodColor(lo);
  return Color.lerp(moodColor(lo), moodColor(hi), m - lo)!;
}

Color moodColorFor(double mean) => moodColor(mean.round().clamp(1, 5));

/// Once-per-day guard for celebrations ("streak milestone", "all habits
/// done"): the moment should feel special, not repeat on every toggle.
abstract final class LifeCelebrations {
  static final Set<String> _fired = {};

  /// True the first time [goal] is claimed on [date]; false afterwards.
  static bool claim(String goal, String date) => _fired.add('$goal|$date');

  static bool claimed(String goal, String date) =>
      _fired.contains('$goal|$date');

  /// For tests and visual QA only.
  static void debugReset() => _fired.clear();
}

/// Small "PRIVATE · ON DEVICE" lock badge.
class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({super.key, this.label = 'PRIVATE · ON DEVICE'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = hud.isDark ? AppColors.habit : AppColors.goldInk;
    return Semantics(
      label: 'Private, stored only on this device',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: c.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 11, color: c),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: hud.label(size: 10.5, color: c),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seven circular day toggles (bit0 = Monday) that spring on tap.
class WeekdayPicker extends StatelessWidget {
  const WeekdayPicker({
    super.key,
    required this.mask,
    required this.onChanged,
    this.single = false,
    this.color,
  });

  final int mask;
  final ValueChanged<int> onChanged;

  /// Exactly one day may be selected (weekly summary).
  final bool single;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.accent;
    return LayoutBuilder(
      builder: (context, box) {
        final size = ((box.maxWidth - 6 * 6) / 7).clamp(34.0, 46.0);
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var d = 1; d <= 7; d++)
              Semantics(
                label: weekdayShort[d - 1],
                selected: maskHasWeekday(mask, d),
                button: true,
                container: true,
                child: PressableScale(
                  haptic: PressHaptic.selection,
                  pressedScale: 0.9,
                  onTap: () {
                    if (single) {
                      onChanged(weekdayBit(d));
                      return;
                    }
                    final on = !maskHasWeekday(mask, d);
                    final next = on
                        ? mask | weekdayBit(d)
                        : mask & ~weekdayBit(d);
                    if (next & allDaysMask != 0) {
                      onChanged(next);
                    } else {
                      Haptics.warning();
                    }
                  },
                  child: ExcludeSemantics(
                    child: _DayDot(
                      letter: weekdayShort[d - 1].substring(0, 2),
                      on: maskHasWeekday(mask, d),
                      color: c,
                      size: size,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DayDot extends StatelessWidget {
  const _DayDot({
    required this.letter,
    required this.on,
    required this.color,
    required this.size,
  });
  final String letter;
  final bool on;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    // Visual disc ≤ 40 dp centred in the (≥ 34 dp, up to 46 dp) tap slot.
    final d = (size - 4).clamp(30.0, 40.0);
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: AnimatedContainer(
          duration: AppMotion.short,
          curve: AppMotion.standard,
          width: d,
          height: d,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? color.withValues(alpha: 0.14) : Colors.transparent,
            border: Border.all(
              color: on
                  ? color.withValues(alpha: 0.7)
                  : hud.hairline.withValues(alpha: hud.isDark ? 0.18 : 0.3),
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              letter.toUpperCase(),
              style: hud.label(
                size: 11.5,
                color: on
                    ? (hud.isDark ? color : hud.accentInk)
                    : hud.textMuted.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<int?> pickMinutes(BuildContext context, int initial) async {
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: (initial ~/ 60) % 24, minute: initial % 60),
  );
  if (t != null) Haptics.selection();
  return t == null ? null : t.hour * 60 + t.minute;
}

/// A tappable mono time readout ("07:30") that opens the time picker.
class HudTimeChip extends StatelessWidget {
  const HudTimeChip({
    super.key,
    required this.minutes,
    required this.onChanged,
    this.label,
    this.onDelete,
    this.color,
  });

  final int minutes;
  final ValueChanged<int> onChanged;

  /// Optional small prefix, e.g. 'AT' or 'FROM'.
  final String? label;
  final VoidCallback? onDelete;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.accent;
    final ink = hud.isDark ? c : hud.accentInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: '${label == null ? '' : '$label '}${formatMinutes(minutes)}',
          hint: 'Change time',
          container: true,
          child: PressableScale(
            haptic: PressHaptic.selection,
            pressedScale: 0.94,
            onTap: () async {
              final v = await pickMinutes(context, minutes);
              if (v != null) onChanged(v);
            },
            child: ExcludeSemantics(
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: EdgeInsets.only(
                  left: 12,
                  right: onDelete == null ? 12 : 4,
                ),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.07),
                  borderRadius: onDelete == null
                      ? BorderRadius.circular(AppRadii.sm)
                      : const BorderRadius.horizontal(
                          left: Radius.circular(AppRadii.sm),
                        ),
                  border: Border.all(color: c.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null) ...[
                      Text(label!, style: hud.label(size: 11)),
                      const SizedBox(width: 8),
                    ] else ...[
                      Icon(Icons.schedule, size: 14, color: ink),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      formatMinutes(minutes),
                      style: hud
                          .mono(size: 15, color: hud.text)
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (onDelete != null) const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (onDelete != null)
          Tooltip(
            message: 'Remove ${formatMinutes(minutes)}',
            child: PressableScale(
              onTap: onDelete,
              pressedScale: 0.85,
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.04),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(AppRadii.sm),
                  ),
                  border: Border(
                    top: BorderSide(color: c.withValues(alpha: 0.35)),
                    right: BorderSide(color: c.withValues(alpha: 0.35)),
                    bottom: BorderSide(color: c.withValues(alpha: 0.35)),
                  ),
                ),
                child: Icon(Icons.close, size: 14, color: hud.textMuted),
              ),
            ),
          ),
      ],
    );
  }
}

/// Editable list of times of day (minutes after midnight).
class TimesEditor extends StatelessWidget {
  const TimesEditor({
    super.key,
    required this.times,
    required this.onChanged,
    this.maxTimes = 6,
    this.addLabel = 'Add time',
    this.color,
  });

  final List<int> times;
  final ValueChanged<List<int>> onChanged;
  final int maxTimes;
  final String addLabel;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final m in times)
          HudTimeChip(
            key: ValueKey('time-$m'),
            minutes: m,
            color: color,
            onChanged: (v) => onChanged(
              ({...times}
                    ..remove(m)
                    ..add(v))
                  .toList()
                ..sort(),
            ),
            onDelete: () => onChanged([...times]..remove(m)),
          ),
        if (times.length < maxTimes)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: HudChip(
              label: addLabel,
              icon: Icons.add,
              color: color,
              onTap: () async {
                final v = await pickMinutes(
                  context,
                  times.isEmpty ? 9 * 60 : (times.last + 60) % 1440,
                );
                if (v == null) return;
                onChanged(({...times, v}).toList()..sort());
              },
            ),
          ),
      ],
    );
  }
}

/// Small rounded label, e.g. "auto" or "Up next".
class TagPill extends StatelessWidget {
  const TagPill(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.textMuted;
    final ink = color != null && !hud.isDark ? hud.text : c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Labelled 1..5 HUD slider: five luminous detents you can tap or drag
/// across (selection haptic per detent). Tapping the selected detent clears
/// it, because every scale here is optional.
class ScaleSelector extends StatelessWidget {
  const ScaleSelector({
    super.key,
    required this.label,
    required this.labels,
    required this.value,
    required this.onChanged,
    this.color = AppColors.brand,
    this.icon,
  });

  final String label;
  final Map<int, String> labels;
  final int? value;
  final ValueChanged<int?> onChanged;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final v = value;
    return Semantics(
      slider: true,
      label: label,
      value: v == null ? 'Not set' : '${labels[v]}, $v of 5',
      increasedValue: labels[((v ?? 0) + 1).clamp(1, 5)],
      decreasedValue: labels[((v ?? 2) - 1).clamp(1, 5)],
      onIncrease: () => onChanged(((v ?? 0) + 1).clamp(1, 5)),
      onDecrease: () => onChanged(((v ?? 2) - 1).clamp(1, 5)),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(label.toUpperCase(), style: hud.label(size: 12)),
              ),
              AnimatedSwitcher(
                duration: AppMotion.short,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.4),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: Text(
                  v == null ? 'Not set' : labels[v]!,
                  key: ValueKey(v),
                  style: t.labelLarge?.copyWith(
                    color: v == null ? hud.textMuted : hud.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _DetentTrack(value: v, color: color, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DetentTrack extends StatefulWidget {
  const _DetentTrack({
    required this.value,
    required this.color,
    required this.onChanged,
  });
  final int? value;
  final Color color;
  final ValueChanged<int?> onChanged;

  @override
  State<_DetentTrack> createState() => _DetentTrackState();
}

class _DetentTrackState extends State<_DetentTrack> {
  bool _dragging = false;

  int _at(double dx, double w) => (dx / w * 5).floor().clamp(0, 4) + 1;

  void _drag(double dx, double w) {
    final i = _at(dx, w);
    if (i != widget.value) {
      Haptics.selection();
      widget.onChanged(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final i = _at(d.localPosition.dx, w);
            Haptics.selection();
            widget.onChanged(widget.value == i ? null : i);
          },
          onHorizontalDragStart: (d) {
            setState(() => _dragging = true);
            _drag(d.localPosition.dx, w);
          },
          onHorizontalDragUpdate: (d) => _drag(d.localPosition.dx, w),
          onHorizontalDragEnd: (_) => setState(() => _dragging = false),
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            height: 40,
            width: double.infinity,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: (widget.value ?? 0).toDouble()),
              duration: AppMotion.reduced(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 420),
              curve: SpringCurve(AppMotion.bouncy),
              builder: (context, v, _) => CustomPaint(
                painter: _DetentPainter(
                  value: v,
                  set: widget.value != null,
                  color: widget.color,
                  hud: hud,
                  dragging: _dragging,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetentPainter extends CustomPainter {
  _DetentPainter({
    required this.value,
    required this.set,
    required this.color,
    required this.hud,
    required this.dragging,
  });
  final double value;
  final bool set;
  final Color color;
  final HudTheme hud;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 5.0;
    final segW = (size.width - gap * 4) / 5;
    const h = 8.0;
    final top = (size.height - h) / 2;
    for (var i = 0; i < 5; i++) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (segW + gap), top, segW, h),
        const Radius.circular(3),
      );
      final fill = (value - i).clamp(0.0, 1.0);
      canvas.drawRRect(
        r,
        Paint()
          ..color = hud.hairline.withValues(alpha: hud.isDark ? 0.1 : 0.16),
      );
      if (fill > 0) {
        final fr = RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (segW + gap), top, segW * fill, h),
          const Radius.circular(3),
        );
        final a = 0.35 + 0.65 * ((i + 1) / 5);
        canvas.drawRRect(
          fr,
          Paint()
            ..shader = LinearGradient(
              colors: [
                color.withValues(alpha: a * 0.7),
                color.withValues(alpha: a),
              ],
            ).createShader(fr.outerRect),
        );
      }
    }
    if (!set || value <= 0.01) return;
    // Thumb: centre of the current detent, white-hot core with bloom.
    final cx = ((value - 1).clamp(0.0, 4.0)) * (segW + gap) + segW / 2;
    final c = Offset(cx, size.height / 2);
    final rad = dragging ? 11.0 : 9.0;
    canvas.drawCircle(
      c,
      rad + 6,
      Paint()
        ..color = color.withValues(alpha: 0.28 * hud.glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(c, rad, Paint()..color = color);
    canvas.drawCircle(
      c,
      rad * 0.42,
      Paint()..color = Color.lerp(color, Colors.white, 0.85)!,
    );
  }

  @override
  bool shouldRepaint(_DetentPainter old) =>
      old.value != value ||
      old.set != set ||
      old.color != color ||
      old.dragging != dragging ||
      old.hud != hud;
}

/// Tactile − value + stepper with a big HUD numeral.
class HudStepper extends StatelessWidget {
  const HudStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.label,
    this.unit,
    this.color,
    this.decreaseTooltip = 'Fewer',
    this.increaseTooltip = 'More',
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Semantic label, e.g. 'Times per week'.
  final String label;

  /// Short caption under the number, e.g. 'PER WEEK'.
  final String? unit;
  final Color? color;
  final String decreaseTooltip;
  final String increaseTooltip;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.accent;
    Widget btn(IconData icon, String tip, int? next) => Tooltip(
      message: tip,
      child: PressableScale(
        enabled: next != null,
        haptic: PressHaptic.selection,
        pressedScale: 0.88,
        onTap: next == null
            ? null
            : () {
                if (next == min || next == max) Haptics.medium();
                onChanged(next);
              },
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.withValues(alpha: next == null ? 0.02 : 0.08),
            border: Border.all(
              color: c.withValues(alpha: next == null ? 0.12 : 0.4),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: next == null ? hud.textMuted.withValues(alpha: 0.5) : c,
          ),
        ),
      ),
    );
    return Semantics(
      label: label,
      value: '$value',
      increasedValue: value < max ? '${value + 1}' : null,
      decreasedValue: value > min ? '${value - 1}' : null,
      onIncrease: value < max ? () => onChanged(value + 1) : null,
      onDecrease: value > min ? () => onChanged(value - 1) : null,
      child: Row(
        children: [
          btn(Icons.remove, decreaseTooltip, value > min ? value - 1 : null),
          Expanded(
            child: Column(
              children: [
                AnimatedTicker(
                  '$value',
                  duration: AppMotion.long,
                  style: hud.number(size: 40),
                ),
                if (unit != null) Text(unit!, style: hud.label(size: 11)),
              ],
            ),
          ),
          btn(Icons.add, increaseTooltip, value < max ? value + 1 : null),
        ],
      ),
    );
  }
}

/// A HUD row: label + optional description on the left, a trailing widget
/// (toggle, chip…) on the right. Use inside cards instead of ListTiles.
class HudRow extends StatelessWidget {
  const HudRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Row(
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: t.titleSmall),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

/// Glass confirm dialog in HUD style (used for deletes and consents).
Future<bool> confirmHud(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
  IconData? icon,
}) async {
  if (destructive) Haptics.heavy();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: icon == null ? null : GlowIcon(icon, size: 26),
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        HudButton(
          label: confirmLabel,
          compact: true,
          variant: destructive
              ? HudButtonVariant.danger
              : HudButtonVariant.primary,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Sentence-case pill for user-facing names (habit names, emotions, rules):
/// Inter text instead of the letter-spaced HUD label, same spring + haptic
/// as [HudChip].
class LifePill extends StatelessWidget {
  const LifePill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = color ?? hud.accent;
    final fg = selected
        ? (hud.isDark ? Color.lerp(c, Colors.white, 0.35)! : hud.text)
        : hud.text.withValues(alpha: 0.86);
    final pill = AnimatedContainer(
      duration: AppMotion.short,
      curve: AppMotion.standard,
      constraints: const BoxConstraints(minHeight: 40),
      padding: EdgeInsets.fromLTRB(icon == null ? 14 : 10, 6, 14, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: c.withValues(alpha: selected ? 0.18 : 0.05),
        border: Border.all(
          color: selected
              ? c.withValues(alpha: 0.75)
              : hud.hairline.withValues(alpha: 0.2),
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.28 * hud.glowStrength),
                  blurRadius: 12,
                  spreadRadius: -3,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 16,
              color: selected || color != null ? c : hud.textMuted,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null
          ? pill
          : PressableScale(
              onTap: onTap,
              haptic: PressHaptic.selection,
              pressedScale: 0.94,
              child: pill,
            ),
    );
  }
}

/// [SectionHeader] whose hint runs the full width underneath (the core
/// header squeezes long subtitles beside its tick line).
class LifeSection extends StatelessWidget {
  const LifeSection(this.title, {super.key, this.hint, this.accent});
  final String title;
  final String? hint;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeader(title, accent: accent),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(left: 13, bottom: AppSpacing.sm),
            child: Text(
              hint!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: hud.textMuted),
            ),
          ),
      ],
    );
  }
}
