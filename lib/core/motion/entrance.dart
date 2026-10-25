import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Plays a one-shot "arrive" animation when first mounted:
/// fade + slight rise + (optional) scale and blur-in.
///
/// ```dart
/// Entrance(delay: Duration(milliseconds: 90), child: card)
/// ```
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.entrance,
    this.offset = const Offset(0, 14),
    this.fromScale = 1,
    this.blur = 0,
    this.curve = AppMotion.emphasizedDecelerate,
    this.enabled = true,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// Start offset in logical pixels (moves to zero).
  final Offset offset;
  final double fromScale;

  /// Initial Gaussian blur sigma. Costly: use on a few hero elements only.
  final double blur;
  final Curve curve;
  final bool enabled;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final total = widget.delay + widget.duration;
    _c = AnimationController(vsync: this, duration: total);
    final start = total.inMicroseconds == 0
        ? 0.0
        : widget.delay.inMicroseconds / total.inMicroseconds;
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: widget.curve),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed && !_done) {
      if (!widget.enabled || AppMotion.reduced(context)) {
        _done = true;
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The widget tree keeps the same shape before, during and after the
  // animation so the child's state is never lost when it finishes.
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final v = _done ? 1.0 : _t.value.clamp(0.0, 1.0);
        final dy = widget.offset * (1 - v);
        final s = widget.fromScale + (1 - widget.fromScale) * v;
        final sigma = widget.blur * (1 - v);
        return Opacity(
          opacity: math.min(1, v * 1.4),
          child: Transform(
            transform: Matrix4.translationValues(dy.dx, dy.dy, 0)
              ..scaleByDouble(s, s, 1, 1),
            alignment: Alignment.center,
            child: ImageFiltered(
              enabled: sigma > 0.05,
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Wraps each widget in an [Entrance] with an increasing delay (capped at
/// [AppMotion.staggerCap] items) for a top-to-bottom cascade.
List<Widget> staggered(
  List<Widget> children, {
  Duration step = AppMotion.staggerStep,
  Duration initialDelay = Duration.zero,
  Offset offset = const Offset(0, 14),
}) => [
  for (var i = 0; i < children.length; i++)
    Entrance(
      key: children[i].key == null ? null : ValueKey(children[i].key),
      delay: initialDelay + step * math.min(i, AppMotion.staggerCap),
      offset: offset,
      child: children[i],
    ),
];

/// A column whose children cascade in on first build.
class StaggeredList extends StatelessWidget {
  const StaggeredList({
    super.key,
    required this.children,
    this.step = AppMotion.staggerStep,
    this.initialDelay = Duration.zero,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.gap = 0,
  });

  final List<Widget> children;
  final Duration step;
  final Duration initialDelay;
  final CrossAxisAlignment crossAxisAlignment;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final items = staggered(children, step: step, initialDelay: initialDelay);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0 && gap > 0) SizedBox(height: gap),
          items[i],
        ],
      ],
    );
  }
}

/// Coordinates automatic entrances for surfaces (e.g. `AppCard`) inside a
/// page: surfaces that mount within [window] of the page appearing cascade
/// in; later ones (scrolling, refresh) appear instantly so the UI never
/// feels slow. Surfaces mounted in the same frame stagger by order.
///
/// Create one per page *state* (not per build) and expose it with
/// [EntranceScope].
class EntranceCoordinator {
  EntranceCoordinator({this.window = const Duration(milliseconds: 2500)})
    : _start = SchedulerBinding.instance.currentSystemFrameTimeStamp;

  final Duration window;
  final Duration _start;
  Duration? _frame;
  int _n = 0;

  /// Returns the delay for a surface mounting now, or null when it should
  /// appear without animation.
  Duration? claim() {
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (now - _start > window) return null;
    if (_frame != now) {
      _frame = now;
      _n = 0;
    }
    final index = _n++;
    return AppMotion.staggerStep * math.min(index, AppMotion.staggerCap);
  }
}

class EntranceScope extends InheritedWidget {
  const EntranceScope({
    super.key,
    required this.coordinator,
    required super.child,
  });

  final EntranceCoordinator coordinator;

  static EntranceCoordinator? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EntranceScope>()?.coordinator;

  @override
  bool updateShouldNotify(EntranceScope oldWidget) =>
      coordinator != oldWidget.coordinator;
}
