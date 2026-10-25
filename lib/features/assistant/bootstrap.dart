import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/paths.dart';
import '../../app/router.dart';
import 'application/providers.dart';
import 'data/assistant_platform.dart';
import 'domain/safe_log.dart';

AppLifecycleListener? _assistantLifecycle;
Timer? _assistantTicker;
StreamSubscription<ShareIntent>? _shareSub;

/// Start-up work for the assistant feature. Must be fast and never throw.
///
/// * Mirrors settings to the native listener (allowlist + kill switch).
/// * Retention purge, then drains the native queue (not awaited).
/// * Subscribes to live captured notifications and share-sheet intents.
/// * On resume: drain + refresh device status. Every minute while alive:
///   scheduled briefings (only while the Dart side is running). Every hour:
///   retention purge (an always-on phone may never restart the app).
Future<void> assistantBootstrap(ProviderContainer container) async {
  try {
    final controller = container.read(assistantControllerProvider);
    final ingestion = container.read(ingestionServiceProvider);
    try {
      await controller.syncNativeConfig().timeout(const Duration(seconds: 1));
    } catch (e) {
      // A slow/failed platform channel must not leave the assistant without
      // live ingestion, drain, purge and lifecycle hooks for the session.
      safeLog('native_config_failed', {'error': errorCode(e)});
    }
    ingestion.start();
    unawaited(
      ingestion
          .purge()
          .then(
            (_) =>
                container.read(replyServiceProvider).recoverInterruptedSends(),
          )
          .then((_) => ingestion.drainAndIngest())
          .then(
            (_) {},
            onError: (Object e) {
              safeLog('bootstrap_drain_failed', {'error': errorCode(e)});
            },
          ),
    );

    final platform = container.read(assistantPlatformProvider);
    unawaited(_startShareIntake(container, platform));
    unawaited(_restoreService(container));

    _assistantLifecycle?.dispose();
    _assistantLifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(
          ingestion.drainAndIngest().then(
            (_) {},
            onError: (Object e) {
              safeLog('resume_drain_failed', {'error': errorCode(e)});
            },
          ),
        );
        container.invalidate(assistantDeviceStatusProvider);
      },
    );

    _assistantTicker?.cancel();
    var lastPurge = DateTime.now();
    _assistantTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(
        container
            .read(briefingServiceProvider)
            .maybePostScheduled()
            .then(
              (_) {},
              onError: (Object e) {
                safeLog('briefing_failed', {'error': errorCode(e)});
              },
            ),
      );
      final now = DateTime.now();
      if (now.difference(lastPurge) >= const Duration(hours: 1)) {
        lastPurge = now;
        unawaited(
          ingestion.purge().then(
            (_) {},
            onError: (Object e) {
              safeLog('retention_purge_failed', {'error': errorCode(e)});
            },
          ),
        );
      }
    });
  } catch (e) {
    safeLog('bootstrap_degraded', {'error': errorCode(e)});
  }
}

/// Cancels the timers, lifecycle listener and share subscription started by
/// [assistantBootstrap] (tests, hot restart).
Future<void> assistantShutdown() async {
  _assistantTicker?.cancel();
  _assistantTicker = null;
  _assistantLifecycle?.dispose();
  _assistantLifecycle = null;
  await _shareSub?.cancel();
  _shareSub = null;
}

/// In-app routes a share/notification intent may open. Exact matches only:
/// the launcher activity is exported, so any app can send this extra.
const _openableRoutes = {
  AppPaths.assistant,
  AppPaths.assistantSettings,
  AppPaths.assistantAudit,
};

@visibleForTesting
bool isOpenableAssistantRoute(String route) => _openableRoutes.contains(route);

Future<void> _restoreService(ProviderContainer container) async {
  try {
    final s = await container.read(assistantRepositoryProvider).settings();
    if (s.serviceEnabled && !s.killSwitch) {
      await container.read(assistantPlatformProvider).startAssistantService();
    }
  } catch (e) {
    safeLog('service_restore_failed', {'error': errorCode(e)});
  }
}

Future<void> _startShareIntake(
  ProviderContainer container,
  AssistantPlatform platform,
) async {
  void handle(ShareIntent s) {
    try {
      final router = container.read(routerProvider);
      if (s.text != null) {
        container.read(pendingShareProvider.notifier).set(s.text);
        router.push(AppPaths.assistant);
      } else if (s.route != null && isOpenableAssistantRoute(s.route!)) {
        router.push(s.route!);
      }
    } catch (e) {
      safeLog('share_intake_failed', {'error': errorCode(e)});
    }
  }

  try {
    await _shareSub?.cancel();
    _shareSub = platform.shareEvents.listen(handle);
    final initial = await platform.getInitialShare().timeout(
      const Duration(seconds: 1),
    );
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => handle(initial));
      // Start-up hooks are time-boxed, so this may resolve after the first
      // frame; make sure another frame (and the callback) actually runs.
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  } catch (e) {
    safeLog('share_intake_failed', {'error': errorCode(e)});
  }
}
