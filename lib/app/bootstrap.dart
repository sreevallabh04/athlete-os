import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/redact.dart';
import '../features/assistant/bootstrap.dart';
import '../features/coach/bootstrap.dart';
import '../features/health/bootstrap.dart';
import '../features/integrations/bootstrap.dart';
import '../features/life/bootstrap.dart';
import '../features/nutrition/bootstrap.dart';
import '../features/onboarding/bootstrap.dart';
import '../features/planning/bootstrap.dart';
import '../features/surfaces/bootstrap.dart';
import '../features/today/bootstrap.dart';
import '../features/train/bootstrap.dart';
import 'day_change.dart';

/// Start-up hooks registered by features (notifications init, timezone setup,
/// backend client...). Each hook must be fast and must not throw; failures are
/// logged (redacted) and the app continues in a degraded mode.
typedef BootstrapHook = Future<void> Function(ProviderContainer container);

final List<BootstrapHook> bootstrapHooks = [
  todayBootstrap,
  trainBootstrap,
  nutritionBootstrap,
  coachBootstrap,
  lifeBootstrap,
  healthBootstrap,
  integrationsBootstrap,
  planningBootstrap,
  assistantBootstrap,
  onboardingBootstrap,
  surfacesBootstrap,
];

/// Longest the first frame waits for the start-up hooks. Hooks run
/// concurrently; any still running after this keep going in the background
/// (a slow plugin, Health Connect or a cold DB must never hold the splash).
const bootstrapBudget = Duration(milliseconds: 1200);

/// Upper bound for a single hook, so a hung future is abandoned (and logged).
const bootstrapHookTimeout = Duration(seconds: 5);

DayChangeWatcher? _dayWatcher;

Future<void> bootstrap(ProviderContainer container) async {
  FlutterError.onError = (details) {
    debugPrint('FlutterError: ${redactSecrets(details.exceptionAsString())}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: ${redactSecrets(error.toString())}');
    return true;
  };
  _dayWatcher?.dispose();
  _dayWatcher = DayChangeWatcher(container)..start();
  await runBootstrapHooks(container, bootstrapHooks, budget: bootstrapBudget);
}

/// Runs [hooks] concurrently, each guarded (errors logged, redacted) and
/// bounded by [hookTimeout]; returns after all finished or after [budget],
/// whichever comes first. Never throws.
@visibleForTesting
Future<void> runBootstrapHooks(
  ProviderContainer container,
  List<BootstrapHook> hooks, {
  required Duration budget,
  Duration hookTimeout = bootstrapHookTimeout,
}) async {
  Future<void> guarded(BootstrapHook hook) async {
    try {
      await Future.sync(() => hook(container)).timeout(hookTimeout);
    } catch (e) {
      debugPrint('Bootstrap hook failed: ${redactSecrets(e.toString())}');
    }
  }

  final all = Future.wait([for (final h in hooks) guarded(h)]);
  await all.timeout(
    budget,
    onTimeout: () {
      debugPrint('Bootstrap budget reached; remaining hooks continue.');
      return const [];
    },
  );
}
