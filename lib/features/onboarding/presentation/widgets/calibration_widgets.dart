import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// Fades + rises its child in after a short index-based stagger.
class Stagger extends StatelessWidget {
  const Stagger({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => Entrance(
    delay: Duration(milliseconds: 70 * index.clamp(0, 10)),
    offset: const Offset(0, 16),
    child: child,
  );
}

/// Big glass answer card (single or multi select) with spring selection.
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.multi = false,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final c = accent ?? hud.accent;
    final reduced = AppMotion.reduced(context);
    return Semantics(
      selected: selected,
      button: true,
      label: subtitle == null ? title : '$title. $subtitle',
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.965,
        child: AnimatedContainer(
          duration: AppMotion.medium,
          curve: AppMotion.emphasizedDecelerate,
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: AppRadii.card,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: selected
                  ? [c.withValues(alpha: 0.20), c.withValues(alpha: 0.05)]
                  : [hud.glassFill, hud.glassFill],
            ),
            border: Border.all(
              color: selected
                  ? c.withValues(alpha: 0.85)
                  : hud.hairline.withValues(alpha: hud.isDark ? 0.14 : 0.3),
              width: selected ? 1.4 : 1,
            ),
            boxShadow: selected
                ? AppGlows.soft(c, strength: hud.glowStrength)
                : null,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                AnimatedContainer(
                  duration: AppMotion.medium,
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.withValues(alpha: selected ? 0.22 : 0.06),
                    border: Border.all(
                      color: c.withValues(alpha: selected ? 0.6 : 0.2),
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected ? c : hud.textMuted,
                    shadows: selected
                        ? AppGlows.text(c, strength: hud.glowStrength)
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TweenAnimationBuilder<double>(
                tween: Tween(end: selected ? 1 : 0),
                duration: reduced ? Duration.zero : AppMotion.long,
                curve: SpringCurve(AppMotion.bouncy),
                builder: (context, v, _) =>
                    _Check(value: v, multi: multi, color: c, hud: hud),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({
    required this.value,
    required this.multi,
    required this.color,
    required this.hud,
  });
  final double value;
  final bool multi;
  final Color color;
  final HudTheme hud;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.2);
    final on = value.clamp(0.0, 1.0);
    final shape = multi ? BoxShape.rectangle : BoxShape.circle;
    final radius = multi ? BorderRadius.circular(6) : null;
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: shape,
              borderRadius: radius,
              border: Border.all(
                color: Color.lerp(
                  hud.textMuted.withValues(alpha: multi ? 0.5 : 0.0),
                  color,
                  on,
                )!,
                width: 1.4,
              ),
            ),
          ),
          if (v > 0.01)
            Transform.scale(
              scale: v,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  shape: shape,
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.6 * hud.glowStrength),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check,
                  size: 15,
                  color: Color(0xFF02141C),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Numeric stepper: big HUD number that rolls on change; hold a button to
/// repeat (with a selection tick per detent).
class NumberStepper extends StatefulWidget {
  const NumberStepper({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.step,
    required this.min,
    required this.max,
    this.format,
    this.unit = '',
    this.helper,
    this.color,
  });

  final String label;
  final double value;
  final double step;
  final double min;
  final double max;
  final String unit;
  final String? helper;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;
  final Color? color;

  @override
  State<NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<NumberStepper> {
  Timer? _repeat;
  int _dir = 0;
  late double _value = widget.value;

  @override
  void didUpdateWidget(NumberStepper old) {
    super.didUpdateWidget(old);
    _value = widget.value;
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  String _fmt(double v) =>
      widget.format?.call(v) ??
      (v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1));

  double _clamp(double v) =>
      double.parse(v.clamp(widget.min, widget.max).toStringAsFixed(2));

  void _bump(int dir) {
    final next = _clamp(_value + widget.step * dir);
    if (next == _value) {
      _stop();
      return;
    }
    Haptics.selection();
    _value = next;
    widget.onChanged(next);
  }

  void _start(int dir) {
    _dir = dir;
    _repeat?.cancel();
    _repeat = Timer.periodic(
      const Duration(milliseconds: 85),
      (_) => _bump(_dir),
    );
  }

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final c = widget.color ?? hud.accent;
    final v = widget.value;
    Widget button(int dir, IconData icon, String tooltip, bool enabled) =>
        Tooltip(
          message: tooltip,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: tooltip,
            excludeSemantics: true,
            child: GestureDetector(
              onLongPressStart: enabled ? (_) => _start(dir) : null,
              onLongPressEnd: (_) => _stop(),
              onLongPressCancel: _stop,
              child: PressableScale(
                onTap: enabled ? () => _bump(dir) : null,
                haptic: PressHaptic.none,
                pressedScale: 0.88,
                child: AnimatedOpacity(
                  duration: AppMotion.short,
                  opacity: enabled ? 1 : 0.35,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.withValues(alpha: 0.08),
                      border: Border.all(color: c.withValues(alpha: 0.4)),
                    ),
                    child: Icon(icon, color: c),
                  ),
                ),
              ),
            ),
          ),
        );
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        children: [
          Text(widget.label.toUpperCase(), style: hud.label(size: 11.5)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              button(
                -1,
                Icons.remove,
                'Decrease ${widget.label}',
                v > widget.min,
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.medium,
                  switchInCurve: AppMotion.emphasizedDecelerate,
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(a),
                      child: child,
                    ),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: _fmt(v), style: hud.number(size: 44)),
                        if (widget.unit.isNotEmpty)
                          TextSpan(
                            text: ' ${widget.unit}',
                            style: t.titleMedium?.copyWith(
                              color: hud.textMuted,
                            ),
                          ),
                      ],
                    ),
                    key: ValueKey(v),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              button(1, Icons.add, 'Increase ${widget.label}', v < widget.max),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 6,
            width: double.infinity,
            child: CustomPaint(
              painter: _ScalePainter(
                t: ((v - widget.min) / (widget.max - widget.min)).clamp(
                  0.0,
                  1.0,
                ),
                color: c,
                hud: hud,
              ),
            ),
          ),
          if (widget.helper != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              widget.helper!,
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ruler with a glowing marker at [t].
class _ScalePainter extends CustomPainter {
  _ScalePainter({required this.t, required this.color, required this.hud});
  final double t;
  final Color color;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 40;
    final tick = Paint()
      ..strokeWidth = 1
      ..color = hud.text.withValues(alpha: 0.18);
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      final h = i % 5 == 0 ? size.height : size.height * 0.5;
      canvas.drawLine(Offset(x, size.height - h), Offset(x, size.height), tick);
    }
    final x = size.width * t;
    canvas.drawLine(
      Offset(x, -2),
      Offset(x, size.height + 1),
      Paint()
        ..strokeWidth = 2
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, 2 * hud.glowStrength),
    );
  }

  @override
  bool shouldRepaint(_ScalePainter old) => old.t != t || old.color != color;
}

/// Row showing a time of day; tapping opens the time picker.
class TimeTile extends StatelessWidget {
  const TimeTile({
    super.key,
    required this.label,
    required this.minutes,
    required this.onChanged,
    this.icon = Icons.schedule,
  });

  final String label;
  final int minutes;
  final IconData icon;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    final text =
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    return Semantics(
      button: true,
      label: '$label, $text. Change',
      excludeSemantics: true,
      child: PressableScale(
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: TimeOfDay(hour: h, minute: m),
          );
          if (picked != null) {
            Haptics.selection();
            onChanged(picked.hour * 60 + picked.minute);
          }
        },
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm + 2,
          ),
          child: Row(
            children: [
              GlowIcon(icon, size: 17, framed: true),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(label, style: t.titleSmall)),
              Text(text, style: hud.number(size: 26)),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.chevron_right, size: 18, color: hud.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single- or multi-select HUD chips.
class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.options,
    required this.isSelected,
    required this.onTap,
    required this.labelOf,
    this.spread = false,
  });

  /// One evenly spaced row (short labels such as weekdays).
  final bool spread;
  final List<T> options;
  final bool Function(T) isSelected;
  final ValueChanged<T> onTap;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    Widget chip(T o) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
      child: HudChip(
        label: labelOf(o),
        selected: isSelected(o),
        onTap: () => onTap(o),
      ),
    );
    if (spread) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [for (final o in options) chip(o)],
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [for (final o in options) chip(o)],
    );
  }
}

/// Editable list of short strings shown as chips (restrictions, dislikes).
class ChipListEditor extends StatefulWidget {
  const ChipListEditor({
    super.key,
    required this.label,
    required this.values,
    required this.onChanged,
    this.hint,
    this.suggestions = const [],
  });

  final String label;
  final String? hint;
  final List<String> values;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;

  @override
  State<ChipListEditor> createState() => _ChipListEditorState();
}

class _ChipListEditorState extends State<ChipListEditor> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add(String v) {
    final s = v.trim();
    if (s.isEmpty || widget.values.contains(s)) return;
    Haptics.selection();
    widget.onChanged([...widget.values, s]);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label.toUpperCase(), style: hud.label(size: 11)),
          if (widget.values.isNotEmpty || widget.suggestions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final v in widget.values)
                  HudChip(
                    label: v,
                    uppercase: false,
                    selected: true,
                    icon: Icons.close,
                    onTap: () => widget.onChanged(
                      widget.values.where((e) => e != v).toList(),
                    ),
                  ),
                for (final s in widget.suggestions)
                  if (!widget.values.contains(s))
                    HudChip(
                      label: s,
                      uppercase: false,
                      icon: Icons.add,
                      onTap: () => _add(s),
                    ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _c,
            decoration: InputDecoration(
              hintText: widget.hint,
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Add',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _add(_c.text),
              ),
            ),
            onSubmitted: _add,
          ),
        ],
      ),
    );
  }
}

/// Calibration progress drawn as a segmented arc (one segment per step),
/// the current segment glowing.
class SegmentedArcProgress extends StatelessWidget {
  const SegmentedArcProgress({
    super.key,
    required this.step,
    required this.count,
    this.width = 168,
  });

  /// Zero-based current step.
  final int step;
  final int count;
  final double width;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: step + 1.0),
      duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.long,
      curve: AppMotion.emphasizedDecelerate,
      builder: (context, v, _) => CustomPaint(
        size: Size(width, width * 0.2),
        painter: _ArcPainter(value: v, count: count, hud: hud),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.value, required this.count, required this.hud});
  final double value;
  final int count;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    const sweepAll = math.pi * 0.5;
    const start = -math.pi / 2 - sweepAll / 2;
    final r = size.width / (2 * math.sin(sweepAll / 2));
    final c = Offset(size.width / 2, r + 5);
    final rect = Rect.fromCircle(center: c, radius: r);
    final seg = sweepAll / count;
    const gap = 0.01;
    for (var i = 0; i < count; i++) {
      final lit = (value - i).clamp(0.0, 1.0);
      final current = value - i > 0 && value - i <= 1.0;
      final a0 = start + i * seg + gap / 2;
      if (current) {
        canvas.drawArc(
          rect,
          a0,
          seg - gap,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 9
            ..color = hud.accent.withValues(alpha: 0.5 * hud.glowStrength)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
      canvas.drawArc(
        rect,
        a0,
        seg - gap,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = current ? 5 : 3.5
          ..color = Color.lerp(
            hud.text.withValues(alpha: hud.isDark ? 0.12 : 0.15),
            current ? Color.lerp(hud.accent, Colors.white, 0.4)! : hud.accent,
            lit,
          )!,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.value != value || old.count != count || old.hud != hud;
}
