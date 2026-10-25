import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/clock.dart';

/// Keeps [localDayProvider] current while the app is open, so every
/// day-scoped provider (Today snapshot, nutrition date, habits, mood, steps,
/// routine...) moves to the new date at local midnight instead of showing
/// yesterday until the app is restarted.
///
/// * A one-shot timer at the next local midnight (+1 s).
/// * A check on every resume: Dart timers run on the monotonic clock, which
///   does not advance while the phone is in deep sleep, so the timer alone can
///   fire hours late.
class DayChangeWatcher {
  DayChangeWatcher(this._container);

  final ProviderContainer _container;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  void start() {
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: check);
    _schedule();
  }

  /// Re-reads the clock (notifies only on a new date) and re-arms the timer.
  void check() {
    try {
      _container.read(localDayProvider.notifier).refresh();
    } catch (_) {
      // Container disposed (tests / hot restart): nothing to refresh.
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final now = _container.read(clockProvider).now();
    final next = DateTime(now.year, now.month, now.day + 1, 0, 0, 1);
    final wait = next.difference(now);
    _timer = Timer(
      wait > Duration.zero ? wait : const Duration(seconds: 1),
      check,
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
