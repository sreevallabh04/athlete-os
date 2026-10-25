import 'dart:async';

import 'package:flutter/services.dart';

import '../motion/motion_tokens.dart';

/// Semantic haptic vocabulary. Components call the *meaning* ("selection",
/// "success"), never raw vibration APIs, so the feel stays consistent and
/// the user can switch everything off in one place.
///
/// | Call            | When                                                |
/// |-----------------|-----------------------------------------------------|
/// | [selection]     | value scrubs, tab/segment changes, picker detents   |
/// | [light]         | ordinary taps on cards, chips, buttons              |
/// | [medium]        | confirming an action (save, log, add)               |
/// | [heavy]         | destructive confirmation, hard limits               |
/// | [success]       | an action completed (medium → light double)         |
/// | [warning]       | validation problem / something needs attention      |
/// | [goalReached]   | a goal ring completes (celebratory cascade)         |
///
/// The global switch is the app setting [settingKey] (default on); the app
/// root keeps [enabled] in sync with it.
abstract final class Haptics {
  /// AppSettings key holding a JSON bool. Default: true.
  static const settingKey = 'ui.haptics';

  /// Global toggle (kept in sync with [settingKey] by the app root).
  static bool enabled = true;

  /// Timed patterns are skipped under `flutter test` (pending timers would
  /// fail widget tests). Tests that want to verify patterns can set this.
  static bool debugAllowPatternsInTests = false;

  /// Optional sink for tests and the dev gallery ("haptic log").
  static void Function(String event)? debugOnEvent;

  static void selection() => _fire('selection', HapticFeedback.selectionClick);
  static void light() => _fire('light', HapticFeedback.lightImpact);
  static void medium() => _fire('medium', HapticFeedback.mediumImpact);
  static void heavy() => _fire('heavy', HapticFeedback.heavyImpact);

  /// Medium → light, 90 ms apart. "Done."
  static void success() => _pattern('success', const [
    (Duration.zero, _Kind.medium),
    (Duration(milliseconds: 90), _Kind.light),
  ]);

  /// Heavy → heavy, 120 ms apart. "Look at this."
  static void warning() => _pattern('warning', const [
    (Duration.zero, _Kind.heavy),
    (Duration(milliseconds: 120), _Kind.heavy),
  ]);

  /// Rising cascade: light, light, medium, heavy… then a soft settle.
  static void goalReached() => _pattern('goalReached', const [
    (Duration.zero, _Kind.light),
    (Duration(milliseconds: 70), _Kind.light),
    (Duration(milliseconds: 140), _Kind.medium),
    (Duration(milliseconds: 230), _Kind.heavy),
    (Duration(milliseconds: 420), _Kind.selection),
  ]);

  static void _fire(String name, Future<void> Function() call) {
    if (!enabled) return;
    debugOnEvent?.call(name);
    unawaited(call().catchError((Object _) {}));
  }

  static void _pattern(String name, List<(Duration, _Kind)> steps) {
    if (!enabled) return;
    debugOnEvent?.call(name);
    final timed = !RuntimeEnv.isFlutterTest || debugAllowPatternsInTests;
    for (final (delay, kind) in steps) {
      if (delay == Duration.zero) {
        unawaited(kind.call().catchError((Object _) {}));
      } else if (timed) {
        Timer(delay, () {
          if (enabled) unawaited(kind.call().catchError((Object _) {}));
        });
      }
    }
  }
}

enum _Kind {
  selection,
  light,
  medium,
  heavy;

  Future<void> call() => switch (this) {
    _Kind.selection => HapticFeedback.selectionClick(),
    _Kind.light => HapticFeedback.lightImpact(),
    _Kind.medium => HapticFeedback.mediumImpact(),
    _Kind.heavy => HapticFeedback.heavyImpact(),
  };
}
