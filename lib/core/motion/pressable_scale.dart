import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart';
import 'motion_tokens.dart';

/// Haptic flavour fired by [PressableScale] on tap.
enum PressHaptic { none, selection, light, medium }

/// Makes any child feel physical: it sinks on press (spring) and rebounds
/// with a small overshoot on release, firing a haptic tick.
///
/// Also handles keyboard activation (Enter/Space) and the click cursor, so
/// it can replace `InkWell` on custom surfaces.
///
/// ```dart
/// PressableScale(onTap: open, child: MyTile())
/// ```
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.965,
    this.haptic = PressHaptic.light,
    this.enabled = true,
    this.behavior = HitTestBehavior.opaque,
    this.onPressedChanged,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while held down (0.94–0.98 reads well; smaller for small chips).
  final double pressedScale;
  final PressHaptic haptic;
  final bool enabled;
  final HitTestBehavior behavior;

  /// Lets parents add a pressed highlight (e.g. brighten a border).
  final ValueChanged<bool>? onPressedChanged;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  bool get _active =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  void _spring(SpringDescription s, double target, {double velocity = 0}) {
    if (!mounted) return;
    if (AppMotion.reduced(context)) {
      _c.value = 1;
      return;
    }
    _c.animateWith(SpringSimulation(s, _c.value, target, velocity));
  }

  void _down() {
    widget.onPressedChanged?.call(true);
    _spring(AppMotion.snappy, widget.pressedScale);
  }

  void _up() {
    widget.onPressedChanged?.call(false);
    // A downward initial velocity makes quick taps still "dip" before the
    // rebound, so even a 20 ms tap is visible.
    _spring(AppMotion.bouncy, 1, velocity: -1.6);
  }

  void _tap() {
    switch (widget.haptic) {
      case PressHaptic.none:
        break;
      case PressHaptic.selection:
        Haptics.selection();
      case PressHaptic.light:
        Haptics.light();
      case PressHaptic.medium:
        Haptics.medium();
    }
    widget.onTap?.call();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaled = AnimatedBuilder(
      animation: _c,
      // Always a Transform (even at 1.0) so the child is never reparented.
      builder: (context, child) =>
          Transform.scale(scale: _c.value, child: child),
      child: widget.child,
    );
    // Same tree whether or not the control is active (no reparenting when a
    // callback appears later, e.g. once data loads).
    return FocusableActionDetector(
      enabled: _active,
      mouseCursor: _active ? SystemMouseCursors.click : MouseCursor.defer,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _tap();
            return null;
          },
        ),
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: _active ? (_) => _down() : null,
        onTapUp: _active ? (_) => _up() : null,
        onTapCancel: _active ? _up : null,
        onTap: !_active || widget.onTap == null ? null : _tap,
        onLongPress: !_active || widget.onLongPress == null
            ? null
            : () {
                Haptics.medium();
                widget.onLongPress!();
              },
        child: scaled,
      ),
    );
  }
}
