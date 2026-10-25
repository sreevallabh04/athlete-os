import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../haptics/haptics.dart';
import '../motion/motion_tokens.dart';
import '../motion/pressable_scale.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'loaders.dart';

/// An icon with a soft bloom. With [framed], it sits in a small glass
/// hexagon-cornered badge (empty states, list leading icons).
class GlowIcon extends StatelessWidget {
  const GlowIcon(
    this.icon, {
    super.key,
    this.color,
    this.size = 22,
    this.glow = 1,
    this.framed = false,
    this.semanticLabel,
  });

  final IconData icon;
  final Color? color;
  final double size;
  final double glow;
  final bool framed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final i = Icon(
      icon,
      size: size,
      color: c,
      semanticLabel: semanticLabel,
      shadows: glow <= 0
          ? null
          : AppGlows.text(c, strength: glow * hud.glowStrength),
    );
    if (!framed) return i;
    final box = size * 2.1;
    return SizedBox.square(
      dimension: box,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [c.withValues(alpha: 0.20), c.withValues(alpha: 0.04)],
          ),
          border: Border.all(color: c.withValues(alpha: 0.35)),
        ),
        child: Center(child: i),
      ),
    );
  }
}

/// Compact HUD chip: letter-spaced technical label, optional icon, tone
/// colour, selectable and tappable.
class HudChip extends StatelessWidget {
  const HudChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
    this.onTap,
    this.uppercase = true,
    this.dot = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;
  final VoidCallback? onTap;
  final bool uppercase;

  /// Leading glowing status dot instead of an icon.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final fg = selected ? c : (color ?? hud.textMuted);
    final scaler = MediaQuery.textScalerOf(context);
    final chip = AnimatedContainer(
      duration: AppMotion.short,
      curve: AppMotion.standard,
      constraints: BoxConstraints(minHeight: scaler.scale(26)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: selected ? 0.16 : 0.06),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: c.withValues(alpha: selected ? 0.65 : 0.22)),
        boxShadow: selected
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
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: c, blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              uppercase ? label.toUpperCase() : label,
              // Rajdhani is for short UPPERCASE labels; mixed-case chips
              // (food names, tags, titles) read better in Inter.
              style: uppercase
                  ? AppTypography.hudLabel(fg, size: 12)
                  : Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: fg, height: 1.2),
              overflow: TextOverflow.ellipsis,
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
          ? chip
          : PressableScale(
              onTap: onTap,
              haptic: PressHaptic.selection,
              pressedScale: 0.94,
              child: chip,
            ),
    );
  }
}

enum HudButtonVariant { primary, secondary, ghost, danger }

/// The HUD call-to-action. Primary = luminous cyan slab with bloom;
/// secondary = glass with a cyan hairline; ghost = text only; danger = red.
/// Springs on press and fires a haptic (medium for primary/danger).
class HudButton extends StatelessWidget {
  const HudButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = HudButtonVariant.primary,
    this.loading = false,
    this.expand = false,
    this.compact = false,
  });

  const HudButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.compact = false,
  }) : variant = HudButtonVariant.secondary;

  const HudButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.compact = false,
  }) : variant = HudButtonVariant.ghost;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final HudButtonVariant variant;
  final bool loading;

  /// Fill the available width.
  final bool expand;

  /// 40 px tall instead of 52.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final enabled = onPressed != null && !loading;
    final base = variant == HudButtonVariant.danger
        ? AppColors.red
        : hud.accent;
    final Color fg;
    final Decoration deco;
    switch (variant) {
      case HudButtonVariant.primary:
      case HudButtonVariant.danger:
        fg = variant == HudButtonVariant.danger
            ? Colors.white
            : const Color(0xFF02141C);
        deco = BoxDecoration(
          borderRadius: AppRadii.button,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: enabled
                ? [Color.lerp(base, Colors.white, 0.18)!, base]
                : [
                    hud.text.withValues(alpha: 0.12),
                    hud.text.withValues(alpha: 0.08),
                  ],
          ),
          boxShadow: enabled
              ? AppGlows.strong(base, strength: 0.7 * hud.glowStrength)
              : null,
        );
      case HudButtonVariant.secondary:
        fg = enabled ? hud.accentInk : hud.textMuted;
        deco = BoxDecoration(
          borderRadius: AppRadii.button,
          color: base.withValues(alpha: enabled ? 0.08 : 0.03),
          border: Border.all(
            color: base.withValues(alpha: enabled ? 0.55 : 0.2),
          ),
        );
      case HudButtonVariant.ghost:
        fg = enabled ? hud.accentInk : hud.textMuted;
        deco = const BoxDecoration();
    }
    final label = Text(
      this.label,
      style: t.labelLarge?.copyWith(
        color: enabled || variant != HudButtonVariant.primary
            ? fg
            : hud.textMuted,
        letterSpacing: 0.3,
      ),
      overflow: TextOverflow.ellipsis,
    );
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading) ...[
          HudSpinner(size: 18, color: fg),
          const SizedBox(width: AppSpacing.sm),
        ] else if (icon != null) ...[
          Icon(icon, size: 18, color: enabled ? fg : hud.textMuted),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(child: label),
      ],
    );
    final body = AnimatedContainer(
      duration: AppMotion.short,
      constraints: BoxConstraints(
        minHeight: compact ? 40 : 52,
        minWidth: compact ? 64 : 88,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.md : AppSpacing.xl,
        vertical: AppSpacing.sm,
      ),
      decoration: deco,
      child: content,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: this.label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled || loading ? 1 : 0.6,
        child: PressableScale(
          onTap: enabled ? onPressed : null,
          behavior: HitTestBehavior.opaque,
          haptic:
              variant == HudButtonVariant.primary ||
                  variant == HudButtonVariant.danger
              ? PressHaptic.medium
              : PressHaptic.light,
          // Compact buttons look 40 px tall but keep a 48 dp touch target.
          child: compact
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.touchTarget,
                  ),
                  child: Center(widthFactor: 1, heightFactor: 1, child: body),
                )
              : body,
        ),
      ),
    );
  }
}

/// HUD switch: glass track, glowing thumb that springs between ends.
class HudToggle extends StatefulWidget {
  const HudToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.color,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final Color? color;

  @override
  State<HudToggle> createState() => _HudToggleState();
}

class _HudToggleState extends State<HudToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.value ? 1 : 0,
  );

  @override
  void didUpdateWidget(HudToggle old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _animateTo(widget.value ? 1 : 0);
  }

  void _animateTo(double target) {
    if (AppMotion.reduced(context)) {
      _c.value = target;
    } else {
      _c.animateWith(SpringSimulation(AppMotion.bouncy, _c.value, target, 0));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = widget.color ?? hud.accent;
    final enabled = widget.onChanged != null;
    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      label: widget.semanticLabel,
      child: PressableScale(
        onTap: enabled
            ? () {
                Haptics.selection();
                widget.onChanged!(!widget.value);
              }
            : null,
        haptic: PressHaptic.none,
        pressedScale: 0.92,
        child: SizedBox(
          width: 56,
          height: AppSpacing.touchTarget,
          child: Center(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final v = _c.value;
                final on = v.clamp(0.0, 1.0);
                return Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: CustomPaint(
                    size: const Size(52, 30),
                    painter: _TogglePainter(v: v, on: on, color: c, hud: hud),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TogglePainter extends CustomPainter {
  _TogglePainter({
    required this.v,
    required this.on,
    required this.color,
    required this.hud,
  });

  final double v;
  final double on;
  final Color color;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(
      r,
      Paint()
        ..color = Color.lerp(
          hud.text.withValues(alpha: hud.isDark ? 0.08 : 0.10),
          color.withValues(alpha: 0.28),
          on,
        )!,
    );
    canvas.drawRRect(
      r.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Color.lerp(
          hud.hairline.withValues(alpha: 0.25),
          color.withValues(alpha: 0.8),
          on,
        )!,
    );
    const pad = 4.0;
    final d = size.height - pad * 2;
    final x = pad + d / 2 + (size.width - pad * 2 - d) * v;
    final center = Offset(x, size.height / 2);
    // Stretch the thumb slightly with spring velocity (overshoot squash).
    final squash = 1 + (v - on).abs() * 1.5;
    if (on > 0) {
      canvas.drawCircle(
        center,
        d / 2 + 3,
        Paint()
          ..color = color.withValues(alpha: 0.55 * on * hud.glowStrength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(squash, 1 / math.sqrt(squash));
    canvas.drawCircle(
      Offset.zero,
      d / 2,
      Paint()
        ..color = Color.lerp(
          hud.isDark ? const Color(0xFF8EA3B8) : Colors.white,
          Color.lerp(color, Colors.white, 0.55)!,
          on,
        )!,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TogglePainter old) =>
      old.v != v || old.color != color || old.hud != hud;
}

/// One option of a [SegmentedHud].
class HudSegment<T> {
  const HudSegment({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

/// Segmented control with a glowing indicator that springs between
/// equal-width segments. Fires a selection haptic on change.
class SegmentedHud<T> extends StatefulWidget {
  const SegmentedHud({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<HudSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  State<SegmentedHud<T>> createState() => _SegmentedHudState<T>();
}

class _SegmentedHudState<T> extends State<SegmentedHud<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
    value: _index.toDouble(),
  );

  void _pick(int i) {
    Haptics.selection();
    widget.onChanged!(widget.segments[i].value);
  }

  int get _index {
    final i = widget.segments.indexWhere((s) => s.value == widget.value);
    return i < 0 ? 0 : i;
  }

  @override
  void didUpdateWidget(SegmentedHud<T> old) {
    super.didUpdateWidget(old);
    final target = _index.toDouble();
    if (_pos.value != target) {
      if (AppMotion.reduced(context)) {
        _pos.value = target;
      } else {
        _pos.animateWith(
          SpringSimulation(AppMotion.bouncy, _pos.value, target, 0),
        );
      }
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final n = widget.segments.length;
    final minH = math.max(44.0, MediaQuery.textScalerOf(context).scale(40));
    return Container(
      constraints: BoxConstraints(minHeight: minH),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: hud.text.withValues(alpha: hud.isDark ? 0.04 : 0.05),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: hud.hairline.withValues(alpha: 0.16)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final segW = box.maxWidth / n;
          return Stack(
            children: [
              AnimatedBuilder(
                animation: _pos,
                builder: (context, _) => Positioned(
                  left: _pos.value * segW,
                  top: 0,
                  bottom: 0,
                  width: segW,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadii.md - 3),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          hud.accent.withValues(alpha: 0.26),
                          hud.accent.withValues(alpha: 0.12),
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
              ),
              Row(
                children: [
                  for (var i = 0; i < n; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == _index,
                        label: widget.segments[i].label,
                        excludeSemantics: true,
                        onTap: widget.onChanged == null || i == _index
                            ? null
                            : () => _pick(i),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onChanged == null || i == _index
                              ? null
                              : () => _pick(i),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: minH - 6),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                                child: AnimatedDefaultTextStyle(
                                  duration: AppMotion.short,
                                  style: t.labelLarge!.copyWith(
                                    color: i == _index
                                        ? hud.text
                                        : hud.textMuted,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (widget.segments[i].icon != null) ...[
                                        Icon(
                                          widget.segments[i].icon,
                                          size: 16,
                                          color: i == _index
                                              ? hud.accent
                                              : hud.textMuted,
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                      Flexible(
                                        child: Text(
                                          widget.segments[i].label,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
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
