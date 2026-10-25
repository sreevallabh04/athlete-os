import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Motion tokens: durations, curves and springs.
///
/// Rules of thumb:
/// * Things the user *touches* move on springs ([AppMotion.snappy] /
///   [AppMotion.bouncy]) so they can be interrupted mid-flight.
/// * Things that *arrive* (pages, cards, data) use [AppMotion.emphasizedDecelerate].
/// * Things that *leave* use [AppMotion.emphasizedAccelerate] and are faster
///   than arrivals (~70 %).
abstract final class AppMotion {
  // Durations
  static const Duration micro = Duration(milliseconds: 90);
  static const Duration short = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration long = Duration(milliseconds: 420);
  static const Duration page = Duration(milliseconds: 420);
  static const Duration pageReverse = Duration(milliseconds: 300);
  static const Duration entrance = Duration(milliseconds: 520);
  static const Duration data = Duration(milliseconds: 900);

  /// Delay between items of a staggered entrance.
  static const Duration staggerStep = Duration(milliseconds: 45);

  /// Items after this index enter together (no endless cascades).
  static const int staggerCap = 8;

  // Curves (Material 3 emphasized family)
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  // Springs
  /// Press feedback, toggles: fast, barely any overshoot.
  static final SpringDescription snappy = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.78,
  );

  /// Release / selection indicators: visible, tasteful overshoot.
  static final SpringDescription bouncy = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380,
    ratio: 0.58,
  );

  /// Large surfaces (sheets, docks): soft and calm.
  static final SpringDescription gentle = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 210,
    ratio: 0.86,
  );

  /// True when the platform asked for reduced motion. Every animated
  /// component must check this and jump to its end state.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// A [Curve] that follows a critically/under-damped spring from 0 to 1.
/// Lets duration-based APIs (route transitions, sheets) feel physical.
class SpringCurve extends Curve {
  SpringCurve(this.spring) : _sim = SpringSimulation(spring, 0, 1, 0) {
    var t = 0.0;
    while (!_sim.isDone(t) && t < 4) {
      t += 1 / 120;
    }
    _settle = t;
  }

  final SpringDescription spring;
  final SpringSimulation _sim;
  late final double _settle;

  @override
  double transformInternal(double t) => _sim.x(t * _settle);
}

/// Runtime environment probes.
abstract final class RuntimeEnv {
  /// True inside `flutter test`. Used to disable GPU shaders, the boot
  /// sequence and timed haptic patterns, which have no meaning headless.
  static final bool isFlutterTest = () {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }();
}
