import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import 'data/google_calendar_service.dart';

/// Start-up work for the integrations feature. Called once from [bootstrap]
/// before the first frame. Must be fast and must not throw.
///
/// Silently restores the Google session (never prompts). If consent expired
/// (Testing-mode OAuth apps: 7 days) the status becomes "needs reconnect".
Future<void> integrationsBootstrap(ProviderContainer container) async {
  if (!Env.hasGoogle) return;
  try {
    unawaited(container.read(googleCalendarServiceProvider).restore());
  } catch (_) {
    // Degraded mode: calendar shows as not connected.
  }
}
