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
///   scheduled briefings (only while the Dart side is running).
Future<void> assistantBootstrap(ProviderContainer container) async {
  try {
    final controller = container.read(assistantControllerProvider);
    final ingestion = container.read(ingestionServiceProvider);
    await controller.syncNativeConfig().timeout(const Duration(seconds: 1));
    ingestion.start();
    unawaited(
      ingestion
          .purge()
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
        unawaited(ingestion.drainAndIngest().then((_) {}, onError: (_) {}));
        container.invalidate(assistantDeviceStatusProvider);
      },
    );

    _assistantTicker?.cancel();
    _assistantTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(
        container
            .read(briefingServiceProvider)
            .maybePostScheduled()
            .then((_) {}, onError: (_) {}),
      );
    });
  } catch (e) {
    safeLog('bootstrap_degraded', {'error': errorCode(e)});
  }
}

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
      } else if (s.route != null && s.route!.startsWith(AppPaths.assistant)) {
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
    }
  } catch (e) {
    safeLog('share_intake_failed', {'error': errorCode(e)});
  }
}
