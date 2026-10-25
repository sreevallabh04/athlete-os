import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../haptics/haptics.dart';
import '../motion/motion_tokens.dart';
import '../motion/pressable_scale.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import 'orb.dart';

/// One destination of the [HudDock].
class HudDockItem {
  const HudDockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.orb = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Render as a mini reactor orb (the AI Coach slot).
  final bool orb;
}

/// Floating glass navigation dock.
///
/// A blurred capsule hovering above the system inset; a luminous indicator
/// springs between slots; icons morph outlined → filled; the [HudDockItem.orb]
/// slot renders as a live mini reactor. Fires a selection haptic.
///
/// Use as `Scaffold.bottomNavigationBar` with `extendBody: true`: the
/// Scaffold then adds the dock's height to `MediaQuery.padding.bottom`, so
/// scroll views and `AppPage` automatically keep content clear of it.
class HudDock extends StatefulWidget {
  const HudDock({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onSelect,
  });

  final List<HudDockItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// Visual height of the capsule.
  static const double barHeight = 68;

  /// Gap between the capsule and the system navigation inset.
  static const double bottomGap = 10;

  @override
  State<HudDock> createState() => _HudDockState();
}

class _HudDockState extends State<HudDock> with SingleTickerProviderStateMixin {
  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
    value: widget.currentIndex.toDouble(),
  );

  @override
  void didUpdateWidget(HudDock old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      final target = widget.currentIndex.toDouble();
      if (AppMotion.reduced(context)) {
        _pos.value = target;
      } else {
        _pos.animateWith(
          SpringSimulation(AppMotion.bouncy, _pos.value, target, _pos.velocity),
        );
      }
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  void _tap(int i) {
    if (i != widget.currentIndex) {
      Haptics.selection();
    } else {
      Haptics.light();
    }
    widget.onSelect(i);
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final barH = HudDock.barHeight + (scaler.scale(11) - 11);
    const radius = BorderRadius.all(Radius.circular(AppRadii.dock));
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          bottom + HudDock.bottomGap,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: hud.isDark ? 0.55 : 0.12),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: CustomPaint(
                painter: _DockGlassPainter(hud),
                child: SizedBox(
                  height: barH,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final n = widget.items.length;
                      final slot = box.maxWidth / n;
                      return Stack(
                        children: [
                          AnimatedBuilder(
                            animation: _pos,
                            builder: (context, _) => _Indicator(
                              position: _pos.value,
                              slot: slot,
                              height: barH,
                              hud: hud,
                              orbIndex: widget.items.indexWhere((e) => e.orb),
                            ),
                          ),
                          Row(
                            children: [
                              for (var i = 0; i < n; i++)
                                SizedBox(
                                  width: slot,
                                  height: barH,
                                  child: _DockSlot(
                                    item: widget.items[i],
                                    selected: i == widget.currentIndex,
                                    onTap: () => _tap(i),
                                    hud: hud,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockGlassPainter extends CustomPainter {
  const _DockGlassPainter(this.hud);
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(AppRadii.dock),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: hud.isDark
              ? const [Color(0xC0101A2A), Color(0xD9070C16)]
              : const [Color(0xE6FFFFFF), Color(0xD9F3F6FA)],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            hud.hairline.withValues(alpha: hud.isDark ? 0.32 : 0.35),
            hud.hairline.withValues(alpha: 0.06),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_DockGlassPainter old) => old.hud != hud;
}

class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.position,
    required this.slot,
    required this.height,
    required this.hud,
    required this.orbIndex,
  });

  final double position;
  final double slot;
  final double height;
  final HudTheme hud;
  final int orbIndex;

  @override
  Widget build(BuildContext context) {
    // Fade the pill out as it approaches the orb slot (the orb has its own
    // glow), and stretch it slightly while travelling.
    final orbFade = orbIndex < 0
        ? 1.0
        : ((position - orbIndex).abs()).clamp(0.0, 1.0);
    final travel = (position - position.roundToDouble()).abs();
    final w = math.min(slot - 10, 58.0) * (1 + travel * 0.5);
    final left = position * slot + (slot - w) / 2;
    final a = hud.accent;
    return Positioned(
      left: left,
      top: 6,
      width: w,
      height: height - 12,
      child: IgnorePointer(
        child: Opacity(
          opacity: orbFade,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        a.withValues(alpha: 0.18),
                        a.withValues(alpha: 0.04),
                      ],
                    ),
                    border: Border.all(color: a.withValues(alpha: 0.22)),
                  ),
                ),
              ),
              // Glowing baseline.
              Positioned(
                left: w * 0.3,
                right: w * 0.3,
                bottom: -6,
                height: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: a,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: a.withValues(alpha: 0.9 * hud.glowStrength),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockSlot extends StatelessWidget {
  const _DockSlot({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.hud,
  });

  final HudDockItem item;
  final bool selected;
  final VoidCallback onTap;
  final HudTheme hud;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = selected ? hud.accentInk : hud.textMuted;
    final Widget glyph;
    if (item.orb) {
      glyph = AnimatedScale(
        scale: selected ? 1.12 : 1,
        duration: AppMotion.medium,
        curve: Curves.easeOutBack,
        child: JarvisOrb(
          size: 34,
          fps: 30,
          state: selected ? OrbState.speaking : OrbState.idle,
          semanticLabel: '',
        ),
      );
    } else {
      glyph = AnimatedSwitcher(
        duration: AppMotion.medium,
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: Tween(begin: 0.6, end: 1.0).animate(anim),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: Icon(
          selected ? item.selectedIcon : item.icon,
          key: ValueKey(selected),
          size: 24,
          color: color,
          shadows: selected
              ? AppGlows.text(hud.accent, strength: hud.glowStrength)
              : null,
        ),
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: PressableScale(
          onTap: onTap,
          haptic: PressHaptic.none,
          pressedScale: 0.88,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 34, child: Center(child: glyph)),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: AppMotion.short,
                style: t.labelSmall!.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0.2,
                ),
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
