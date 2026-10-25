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

Future<void> bootstrap(ProviderContainer container) async {
  FlutterError.onError = (details) {
    debugPrint('FlutterError: ${redactSecrets(details.exceptionAsString())}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: ${redactSecrets(error.toString())}');
    return true;
  };
  for (final hook in bootstrapHooks) {
    try {
      await hook(container).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Bootstrap hook failed: ${redactSecrets(e.toString())}');
    }
  }
}
