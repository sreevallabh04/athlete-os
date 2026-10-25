import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/redact.dart';
import '../../data/repositories/integration_status_repository.dart';
import 'application/health_providers.dart';
import 'application/health_sync_service.dart';

AppLifecycleListener? _healthLifecycleListener;

/// Start-up work for the health feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
///
/// * Configures the `health` plugin (bounded by a short timeout).
/// * If Health Connect was set up before, starts a sync WITHOUT awaiting it.
/// * Registers an app-resume listener that syncs at most every 5 minutes.
Future<void> healthBootstrap(ProviderContainer container) async {
  try {
    final ds = container.read(healthDataSourceProvider);
    await ds.configure().timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('Health bootstrap: configure: ${redactSecrets('$e')}');
  }

  try {
    final groups = await container
        .read(healthSettingsProvider)
        .enabledGroups()
        .timeout(const Duration(seconds: 1));
    final status = await container
        .read(integrationStatusRepositoryProvider)
        .get(Providers.healthConnect)
        .timeout(const Duration(seconds: 1));
    final previouslyConnected =
        groups.isNotEmpty ||
        status?.status == ConnectionStates.connected ||
        status?.lastSyncAt != null;
    if (previouslyConnected) {
      unawaited(
        container
            .read(healthSyncServiceProvider)
            .sync(trigger: SyncTrigger.appStart)
            .then((_) {}, onError: (_) {}),
      );
    }
  } catch (e) {
    debugPrint('Health bootstrap: start sync: ${redactSecrets('$e')}');
  }

  try {
    _healthLifecycleListener?.dispose();
    _healthLifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_syncOnResume(container)),
    );
  } catch (e) {
    debugPrint('Health bootstrap: lifecycle: ${redactSecrets('$e')}');
  }
}

/// Resume trigger: only when the user has enabled at least one group, and
/// throttled to one sync per 5 minutes.
Future<void> _syncOnResume(ProviderContainer container) async {
  try {
    final groups = await container.read(healthSettingsProvider).enabledGroups();
    if (groups.isEmpty) return;
    await container.read(healthSyncServiceProvider).syncIfStale();
  } catch (e) {
    debugPrint('Health resume sync: ${redactSecrets('$e')}');
  }
}
