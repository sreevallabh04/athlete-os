import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/countdown.dart';

/// Start-up work for the planning feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
Future<void> planningBootstrap(ProviderContainer container) async {
  // Load the IANA timezone database once so countdowns never block a frame.
  try {
    ensureTimeZonesInitialized();
  } catch (_) {}
}
