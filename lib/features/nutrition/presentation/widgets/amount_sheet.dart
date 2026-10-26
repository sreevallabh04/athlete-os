import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/domain/provenance.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/food_models.dart';
import '../../domain/nutrients.dart';
import 'common.dart';
import 'nutrition_hud.dart';

class AmountSheetResult {
  const AmountSheetResult(this.amount, this.meal);
  final Amount amount;
  final MealType? meal;
}

/// Frosted sheet to choose an amount (servings or grams) with a tactile
/// stepper + scrub ruler and a live macro preview, and optionally the meal.
/// Returns null when dismissed.
Future<AmountSheetResult?> showAmountSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required ServingBasis basis,
  required String verification,
  required DataOrigin origin,
  MealType? initialMeal,
  String actionLabel = 'Log',
  bool showOffAttribution = false,
  Amount? initialAmount,
  Widget? extra,
}) {
  return showHudBottomSheet<AmountSheetResult>(
    context,
    builder: (_) => AmountSheet(
      title: title,
      subtitle: subtitle,
      basis: basis,
      verification: verification,
      origin: origin,
      initialMeal: initialMeal,
      actionLabel: actionLabel,
      showOffAttribution: showOffAttribution,
      initialAmount: initialAmount,
      extra: extra,
    ),
  );
}

class AmountSheet extends StatefulWidget {
  const AmountSheet({
    super.key,
    required this.title,
    this.subtitle,
    required this.basis,
    required this.verification,
    required this.origin,
    this.initialMeal,
    this.actionLabel = 'Log',
    this.showOffAttribution = false,
    this.initialAmount,
    this.extra,
  });

  final String title;
  final String? subtitle;
  final ServingBasis basis;
  final String verification;
  final DataOrigin origin;
  final MealType? initialMeal;
  final String actionLabel;
  final bool showOffAttribution;
  final Amount? initialAmount;
  final Widget? extra;

  @override
  State<AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<AmountSheet> {
  late AmountMode _mode;
  late final TextEditingController _ctrl;
  MealType? _meal;

  @override
  void initState() {
    super.initState();
    final init = widget.initialAmount;
    _mode = init?.mode ?? AmountMode.servings;
    if (_mode == AmountMode.grams && !widget.basis.supportsGrams) {
      _mode = AmountMode.servings;
    }
    _ctrl = TextEditingController(
      text: init != null ? plainNum(init.value) : '1',
    );
    _meal = widget.initialMeal;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (v == null || !v.isFinite || v <= 0 || v > 100000) return null;
    return v;
  }

  Amount? get _amount {
    final v = _value;
    if (v == null) return null;
    return _mode == AmountMode.grams ? Amount.grams(v) : Amount.servings(v);
  }

  void _setValue(double v) => setState(() => _ctrl.text = plainNum(v));

  void _switchMode(AmountMode m) {
    final current = _value;
    final gps = widget.basis.gramsPerServing;
    setState(() {
      if (current != null && gps != null && gps > 0) {
        final converted = m == AmountMode.grams ? current * gps : current / gps;
        _ctrl.text = plainNum(converted);
      } else {
        _ctrl.text = m == AmountMode.grams ? plainNum(gps ?? 100) : '1';
      }
      _mode = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final amount = _amount;
    final preview = amount == null
        ? null
        : resolveAmount(widget.basis, amount).nutrients;
    final unit = widget.basis.baseUnit;
    final estimate = Verifications.isEstimate(widget.verification);
    final grams = _mode == AmountMode.grams;
    final presets = grams
        ? const [50.0, 100.0, 150.0, 200.0, 250.0]
        : const [0.5, 1.0, 1.5, 2.0, 3.0];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title, style: t.titleLarge),
          if (widget.subtitle != null)
            Text(
              widget.subtitle!,
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SourceBadge(origin: widget.origin, isEstimate: estimate),
              VerificationLabel(widget.verification),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            // Units keep their case ("100 g", not "100 G").
            '1 serving = ${widget.basis.servingLabel} · '
            '${Fmt.kcal(widget.basis.perServing.calories)}',
            style: hud.mono(size: 10.5),
          ),
          if (widget.showOffAttribution) ...[
            const SizedBox(height: AppSpacing.xs),
            const OffAttribution(),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (widget.basis.supportsGrams) ...[
            SegmentedHud<AmountMode>(
              segments: [
                const HudSegment(value: AmountMode.servings, label: 'Servings'),
                HudSegment(
                  value: AmountMode.grams,
                  label: unit == 'ml' ? 'Millilitres' : 'Grams',
                ),
              ],
              value: _mode,
              onChanged: _switchMode,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AmountStepper(
            controller: _ctrl,
            unitLabel: grams
                ? switch (unit) {
                    'g' => 'grams',
                    'ml' => 'millilitres',
                    _ => unit,
                  }
                : (_value == 1 ? 'serving' : 'servings'),
            step: grams ? 5 : 0.25,
            max: grams ? 3000 : 30,
            valid: amount != null,
            onChanged: (v) => _setValue(v),
            onTyped: () => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final c in presets)
                HudChip(
                  label: grams ? '${Fmt.oneDp(c)} $unit' : '${Fmt.oneDp(c)}×',
                  selected: _value == c,
                  onTap: () => _setValue(c),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          GlassPanel(
            accent: estimate ? AppColors.warning : null,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
            ),
            child: preview == null
                ? Center(
                    child: Text(
                      'Enter an amount to preview',
                      style: t.bodyMedium?.copyWith(color: hud.textMuted),
                    ),
                  )
                : Column(
                    children: [
                      NutrientPreview(nutrients: preview, estimate: estimate),
                      const SizedBox(height: AppSpacing.md),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        child: MacroSplitBar(
                          protein: preview.protein,
                          carbs: preview.carbs,
                          fat: preview.fat,
                        ),
                      ),
                    ],
                  ),
          ),
          if (_meal != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text('MEAL', style: hud.label(size: 11)),
            const SizedBox(height: AppSpacing.sm),
            MealPicker(
              value: _meal!,
              onChanged: (m) => setState(() => _meal = m),
            ),
          ],
          if (widget.extra != null) ...[
            const SizedBox(height: AppSpacing.md),
            DefaultTextStyle.merge(
              style: t.bodySmall?.copyWith(color: hud.textMuted),
              child: widget.extra!,
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          HudButton(
            label: widget.actionLabel == 'Log' && _meal != null
                ? 'Log to ${_meal!.label}'
                : widget.actionLabel,
            icon: Icons.check_rounded,
            expand: true,
            onPressed: amount == null
                ? null
                : () {
                    Haptics.success();
                    Navigator.of(context).pop(AmountSheetResult(amount, _meal));
                  },
          ),
        ],
      ),
    );
  }
}

/// Tactile amount control: − / big editable number / +, with hold-to-repeat
/// and a scrub ruler underneath that ticks a haptic on every detent.
class AmountStepper extends StatelessWidget {
  const AmountStepper({
    super.key,
    required this.controller,
    required this.unitLabel,
    required this.step,
    required this.max,
    required this.valid,
    required this.onChanged,
    required this.onTyped,
  });

  final TextEditingController controller;
  final String unitLabel;
  final double step;
  final double max;
  final bool valid;
  final ValueChanged<double> onChanged;
  final VoidCallback onTyped;

  double get _current =>
      double.tryParse(controller.text.trim().replaceAll(',', '.')) ?? 0;

  void _nudge(int dir) {
    final v = _current;
    // Snap to the step grid first, then move one detent.
    final snapped = (v / step).round() * step;
    var next = snapped == v ? v + dir * step : snapped;
    if (dir > 0 && next < v) next += step;
    if (dir < 0 && next > v) next -= step;
    next = next.clamp(step, max);
    if (next != v) {
      Haptics.selection();
      onChanged(next);
    } else {
      Haptics.light();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      children: [
        Row(
          children: [
            _RepeatButton(
              icon: Icons.remove_rounded,
              label: 'Decrease',
              onStep: () => _nudge(-1),
            ),
            Expanded(
              child: Column(
                children: [
                  TextField(
                    key: const Key('amount-field'),
                    controller: controller,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    style: hud.number(
                      size: 44,
                      color: valid ? hud.text : AppColors.danger,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    onChanged: (_) => onTyped(),
                  ),
                  Text(
                    valid ? unitLabel.toUpperCase() : 'ENTER AN AMOUNT ABOVE 0',
                    style: hud.label(
                      size: 11,
                      color: valid ? hud.textMuted : AppColors.danger,
                    ),
                  ),
                ],
              ),
            ),
            _RepeatButton(
              icon: Icons.add_rounded,
              label: 'Increase',
              onStep: () => _nudge(1),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ScrubRuler(value: _current, step: step, max: max, onChanged: onChanged),
      ],
    );
  }
}

class _RepeatButton extends StatefulWidget {
  const _RepeatButton({
    required this.icon,
    required this.label,
    required this.onStep,
  });

  final IconData icon;
  final String label;
  final VoidCallback onStep;

  @override
  State<_RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<_RepeatButton> {
  Timer? _delay;
  Timer? _repeat;
  bool _down = false;

  void _start() {
    setState(() => _down = true);
    widget.onStep();
    _delay = Timer(const Duration(milliseconds: 380), () {
      _repeat = Timer.periodic(
        const Duration(milliseconds: 85),
        (_) => widget.onStep(),
      );
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    if (mounted && _down) setState(() => _down = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onStep,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: AnimatedScale(
          scale: _down ? 0.9 : 1,
          duration: AppMotion.micro,
          curve: AppMotion.standard,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hud.accent.withValues(alpha: _down ? 0.2 : 0.08),
              border: Border.all(
                color: hud.accent.withValues(alpha: _down ? 0.8 : 0.4),
              ),
              boxShadow: _down
                  ? AppGlows.soft(hud.accent, strength: hud.glowStrength)
                  : null,
            ),
            child: Icon(widget.icon, color: hud.accentInk, size: 26),
          ),
        ),
      ),
    );
  }
}

/// Horizontal ruler you drag to scrub a value; fires a selection haptic on
/// every detent.
class ScrubRuler extends StatefulWidget {
  const ScrubRuler({
    super.key,
    required this.value,
    required this.step,
    required this.max,
    required this.onChanged,
    this.color,
  });

  final double value;
  final double step;
  final double max;
  final ValueChanged<double> onChanged;
  final Color? color;

  @override
  State<ScrubRuler> createState() => _ScrubRulerState();
}

class _ScrubRulerState extends State<ScrubRuler> {
  static const _spacing = 11.0;
  double? _dragStartValue;
  double _dx = 0;

  void _update(double dx) {
    final start = _dragStartValue;
    if (start == null) return;
    _dx += dx;
    final steps = (-_dx / _spacing).round();
    final base = (start / widget.step).round() * widget.step;
    final next = (base + steps * widget.step).clamp(widget.step, widget.max);
    if (next != widget.value) {
      Haptics.selection();
      widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      slider: true,
      label: 'Amount ruler',
      value: Fmt.oneDp(widget.value),
      increasedValue: Fmt.oneDp(widget.value + widget.step),
      decreasedValue: Fmt.oneDp(
        math.max(widget.step, widget.value - widget.step),
      ),
      onIncrease: () =>
          widget.onChanged((widget.value + widget.step).clamp(0, widget.max)),
      onDecrease: () =>
          widget.onChanged(math.max(widget.step, widget.value - widget.step)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _dragStartValue = widget.value;
          _dx = 0;
        },
        onHorizontalDragUpdate: (d) => _update(d.delta.dx),
        onHorizontalDragEnd: (_) => _dragStartValue = null,
        child: SizedBox(
          height: 46,
          width: double.infinity,
          child: CustomPaint(
            painter: _RulerPainter(
              value: widget.value,
              step: widget.step,
              spacing: _spacing,
              hud: hud,
              color: widget.color ?? hud.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.value,
    required this.step,
    required this.spacing,
    required this.hud,
    required this.color,
  });

  final double value;
  final double step;
  final double spacing;
  final HudTheme hud;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final base = size.height - 14;
    final first = ((value - cx / spacing * step) / step).floor();
    final last = ((value + cx / spacing * step) / step).ceil();
    final tick = Paint()..strokeCap = StrokeCap.round;
    final labelStyle = AppTypography.mono(hud.textMuted, size: 9);
    for (var i = math.max(0, first); i <= last; i++) {
      final v = i * step;
      final x = cx + (v - value) / step * spacing;
      final dist = ((x - cx).abs() / cx).clamp(0.0, 1.0);
      final fade = 1 - dist * dist;
      final major = i % 10 == 0;
      final mid = i % 5 == 0;
      tick
        ..strokeWidth = major ? 1.6 : 1
        ..color = hud.hairline.withValues(
          alpha: (major ? 0.55 : 0.28) * fade * (hud.isDark ? 1 : 1.3),
        );
      final h = major ? 18.0 : (mid ? 12.0 : 7.0);
      canvas.drawLine(Offset(x, base), Offset(x, base - h), tick);
      if (major) {
        final tp = TextPainter(
          text: TextSpan(
            text: Fmt.oneDp(v),
            style: labelStyle.copyWith(
              color: labelStyle.color!.withValues(alpha: fade),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, base + 2));
      }
    }
    // Centre needle.
    final needle = Paint()
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(
      Offset(cx, base + 2),
      Offset(cx, base - 26),
      Paint()
        ..strokeWidth = 7
        ..color = color.withValues(alpha: 0.3 * hud.glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawLine(Offset(cx, base + 2), Offset(cx, base - 26), needle);
    final tri = Path()
      ..moveTo(cx - 5, 0)
      ..lineTo(cx + 5, 0)
      ..lineTo(cx, 6)
      ..close();
    canvas.drawPath(tri, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value ||
      old.step != step ||
      old.hud != hud ||
      old.color != color;
}

/// Meal chooser: four tactile tiles with a glowing indicator that springs
/// between them.
class MealPicker extends StatelessWidget {
  const MealPicker({super.key, required this.value, required this.onChanged});
  final MealType value;
  final ValueChanged<MealType> onChanged;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final reduced = AppMotion.reduced(context);
    final index = MealType.values.indexOf(value);
    const n = 4;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: hud.text.withValues(alpha: hud.isDark ? 0.04 : 0.05),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: hud.hairline.withValues(alpha: 0.16)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / n;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: reduced ? Duration.zero : AppMotion.long,
                curve: SpringCurve(AppMotion.bouncy),
                left: index * w,
                top: 0,
                bottom: 0,
                width: w,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md - 3),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        hud.accent.withValues(alpha: 0.24),
                        hud.accent.withValues(alpha: 0.10),
                      ],
                    ),
                    border: Border.all(
                      color: hud.accent.withValues(alpha: 0.6),
                    ),
                    boxShadow: AppGlows.soft(
                      hud.accent,
                      strength: hud.glowStrength,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final m in MealType.values)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: m == value,
                        label: m.label,
                        excludeSemantics: true,
                        onTap: m == value ? null : () => onChanged(m),
                        child: PressableScale(
                          haptic: PressHaptic.selection,
                          pressedScale: 0.94,
                          onTap: m == value ? null : () => onChanged(m),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 56),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 2,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    mealIcon(m),
                                    size: 18,
                                    color: m == value
                                        ? hud.accentInk
                                        : hud.textMuted,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    m.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.labelMedium?.copyWith(
                                      color: m == value
                                          ? hud.text
                                          : hud.textMuted,
                                      fontWeight: m == value
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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
