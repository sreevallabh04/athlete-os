import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// One entry of the [QuickAddFab] speed dial.
class QuickAction {
  const QuickAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.ai = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// Marks AI-assisted actions with a small JARVIS-cyan "AI" tag.
  final bool ai;
}

/// Primary "log food" button that blooms into a speed dial: the actions
/// spring out along a gentle arc above it, over a frosted scrim. Tap the
/// scrim, the × or system back to close.
class QuickAddFab extends StatelessWidget {
  const QuickAddFab({
    super.key,
    required this.actions,
    this.label = 'Log food',
  });

  /// Ordered nearest-first (index 0 sits right above the button).
  final List<QuickAction> actions;
  final String label;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    Haptics.medium();
    final picked = await Navigator.of(context, rootNavigator: true).push(
      _SpeedDialRoute(
        anchor: anchor,
        actions: actions,
        reduced: AppMotion.reduced(context),
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
      ),
    );
    picked?.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label: open quick add menu',
      excludeSemantics: true,
      onTap: () => _open(context),
      child: Builder(
        builder: (context) => PressableScale(
          haptic: PressHaptic.none,
          pressedScale: 0.92,
          onTap: () => _open(context),
          child: const _FabCore(turns: 0),
        ),
      ),
    );
  }
}

class _FabCore extends StatelessWidget {
  const _FabCore({required this.turns});
  final double turns;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(hud.accent, Colors.white, 0.06)!,
            Color.lerp(hud.accent, Colors.black, 0.14)!,
          ],
        ),
        boxShadow: AppGlows.strong(hud.accent, strength: hud.glowStrength),
      ),
      child: Transform.rotate(
        angle: turns * math.pi / 4,
        child: const Icon(Icons.add_rounded, size: 32, color: Colors.white),
      ),
    );
  }
}

class _SpeedDialRoute extends PopupRoute<QuickAction> {
  _SpeedDialRoute({
    required this.anchor,
    required this.actions,
    required this.reduced,
    required this.barrierLabel,
  });

  final Rect anchor;
  final List<QuickAction> actions;
  final bool reduced;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 560);

  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 220);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _SpeedDial(anchor: anchor, actions: actions, animation: animation);
}

class _SpeedDial extends StatelessWidget {
  const _SpeedDial({
    required this.anchor,
    required this.actions,
    required this.animation,
  });

  final Rect anchor;
  final List<QuickAction> actions;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final hud = context.hud;
    final spring = SpringCurve(AppMotion.bouncy);
    const rowH = 60.0;
    final n = actions.length;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final a = animation.value;
        final reversing = animation.status == AnimationStatus.reverse;
        return Stack(
          children: [
            // Frosted scrim.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 8 * a, sigmaY: 8 * a),
                  child: ColoredBox(
                    color: (hud.isDark ? Colors.black : AppColors.lightText)
                        .withValues(alpha: 0.55 * a),
                  ),
                ),
              ),
            ),
            for (var i = 0; i < n; i++)
              _item(context, i, n, a, reversing, spring, rowH, size),
            // The FAB itself, morphing + → ×.
            Positioned(
              left: anchor.left,
              top: anchor.top,
              width: anchor.width,
              height: anchor.height,
              child: Semantics(
                button: true,
                label: 'Close quick add menu',
                child: PressableScale(
                  haptic: PressHaptic.light,
                  onTap: () => Navigator.of(context).pop(),
                  child: Center(
                    child: _FabCore(
                      turns: (reversing ? a : spring.transform(a)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _item(
    BuildContext context,
    int i,
    int n,
    double a,
    bool reversing,
    Curve spring,
    double rowH,
    Size size,
  ) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    // Staggered local progress.
    const stagger = 0.07;
    final start = i * stagger;
    final local = ((a - start) / (1 - stagger * (n - 1))).clamp(0.0, 1.0);
    final p = reversing ? local : spring.transform(local);
    final fade = local.clamp(0.0, 1.0);
    // Gentle arc: items further up drift slightly left.
    final arc = math.sin((i + 1) / (n + 1) * math.pi) * 14;
    final bottom = size.height - anchor.top + 8 + i * rowH;
    final right = size.width - anchor.right + (anchor.width - 48) / 2 + arc;
    final action = actions[i];
    return Positioned(
      right: right,
      bottom: bottom - (1 - p) * (i + 1) * 18,
      child: Opacity(
        opacity: fade,
        child: Transform.scale(
          scale: 0.6 + 0.4 * p,
          alignment: Alignment.centerRight,
          child: Semantics(
            button: true,
            label: action.ai ? '${action.label}, AI assisted' : action.label,
            excludeSemantics: true,
            onTap: () => Navigator.of(context).pop(action),
            child: PressableScale(
              onTap: () => Navigator.of(context).pop(action),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: size.width * 0.6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: hud.glassFillStrong,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      border: Border.all(
                        color: hud.hairline.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            action.label,
                            style: t.labelLarge?.copyWith(color: hud.text),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (action.ai) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: hud.jarvis.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Text(
                              'AI',
                              style: AppTypography.hudLabel(
                                hud.jarvisInk,
                                size: 9.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hud.glassFillStrong,
                      border: Border.all(
                        color: hud.accent.withValues(alpha: 0.55),
                      ),
                      boxShadow: AppGlows.soft(
                        hud.accent,
                        strength: hud.glowStrength,
                      ),
                    ),
                    child: Icon(action.icon, color: hud.accentInk, size: 22),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
