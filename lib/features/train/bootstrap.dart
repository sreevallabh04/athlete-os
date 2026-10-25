import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/util/redact.dart';
import '../../data/repositories/integration_status_repository.dart';
import 'application/train_providers.dart';
import 'data/hevy_sync_service.dart';
import 'data/strava_sync_service.dart';

/// Start-up work for the train feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
///
/// * Enforces the Strava 7-day cache rule (local delete, no network).
/// * Schedules a background Hevy/Strava sync a few seconds after start with
///   random jitter (never aligned to :00, as Hevy's docs request).
Future<void> trainBootstrap(ProviderContainer container) async {
  try {
    await container.read(stravaSyncServiceProvider).enforceCacheRule();
  } catch (e) {
    debugPrint('Strava cache purge failed: ${redactSecrets(e.toString())}');
  }
  unawaited(_backgroundSync(container));
}

Future<void> _backgroundSync(ProviderContainer container) async {
  try {
    await Future<void>.delayed(
      Duration(seconds: 5 + math.Random().nextInt(20)),
    );
    final status = container.read(integrationStatusRepositoryProvider);
    final sync = container.read(syncControllerProvider.notifier);
    final hevy = await status.get(Providers.hevy);
    if (isConnected(hevy) &&
        await container.read(hevySyncServiceProvider).hasKey()) {
      await sync.syncHevy();
    }
    final strava = await status.get(Providers.strava);
    if (Env.hasStrava && isConnected(strava)) await sync.syncStrava();
  } catch (e) {
    debugPrint('Background sync failed: ${redactSecrets(e.toString())}');
  }
}
