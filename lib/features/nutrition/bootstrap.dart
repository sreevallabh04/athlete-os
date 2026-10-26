import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../core/config/env.dart';
import '../../data/repositories/integration_status_repository.dart';
import 'data/device_tz.dart';

/// Start-up work for the nutrition feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
Future<void> nutritionBootstrap(ProviderContainer container) async {
  try {
    final tz = await FlutterTimezone.getLocalTimezone().timeout(
      const Duration(seconds: 2),
    );
    DeviceTz.iana = tz.identifier;
  } catch (_) {
    // Fallback to the platform abbreviation (see DeviceTz.name).
  }
  try {
    // USDA works with the public DEMO_KEY when no personal key is set, so it
    // is never "awaiting credentials"; clear a stale status from older builds.
    if (Env.usdaIsDemo) {
      final status = container.read(integrationStatusRepositoryProvider);
      final existing = await status.get(Providers.usda);
      if (existing != null &&
          existing.status == ConnectionStates.awaitingCredentials) {
        await status.setStatus(
          Providers.usda,
          ConnectionStates.needsSetup,
          clearError: true,
        );
      }
    }
  } catch (_) {
    // Never block startup.
  }
}
