import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/util/redact.dart';
import '../../data/repositories/integration_status_repository.dart';
import '../../data/repositories/settings_repository.dart';
import 'data/coach_auth.dart';

/// Start-up work for the coach feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
///
/// Initialises Supabase only when the build has `SUPABASE_URL` and
/// `SUPABASE_ANON_KEY`; otherwise the AI backend is recorded as awaiting
/// credentials and the coach shows its setup guide.
Future<void> coachBootstrap(ProviderContainer container) async {
  try {
    await CoachSupabase.init();
    final repo = container.read(integrationStatusRepositoryProvider);
    final existing = await repo.get(Providers.aiBackend);
    if (!Env.hasSupabase || !CoachSupabase.ready) {
      await repo.setStatus(
        Providers.aiBackend,
        ConnectionStates.awaitingCredentials,
        error: Env.hasSupabase ? 'Supabase could not be initialised.' : null,
      );
    } else if (existing == null ||
        existing.status == ConnectionStates.awaitingCredentials) {
      // Configured, but never verified by a real call yet.
      await repo.setStatus(Providers.aiBackend, ConnectionStates.needsSetup);
    }
    if (CoachSupabase.ready) {
      // First launch: get an anonymous session without user action. Not
      // awaited so a slow network never delays the first frame.
      unawaited(
        ensureAnonymousSession(
          container.read(coachAuthProvider),
          container.read(settingsRepositoryProvider),
        ),
      );
    }
  } catch (e) {
    debugPrint('coachBootstrap: ${redactSecrets(e.toString())}');
  }
}
