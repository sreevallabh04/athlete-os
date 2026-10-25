import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/paths.dart' show rootNavigatorKey;
import '../../app/router.dart';
import '../../core/time/clock.dart';
import '../../core/util/redact.dart';
import '../onboarding/application/persona_providers.dart';
import '../today/application/today_providers.dart';
import 'application/deep_link_router.dart';
import 'application/water_queue_drainer.dart';
import 'application/widget_sync.dart';
import 'data/surfaces_platform.dart';
import 'domain/deep_links.dart';
import 'domain/widget_snapshot.dart';
import 'presentation/water_quick_add_sheet.dart';

StreamSubscription<SurfaceEvent>? _eventsSub;
ProviderSubscription<WidgetSnapshot?>? _snapshotSub;
AppLifecycleListener? _lifecycle;
Timer? _midnight;

/// Start-up work for the home-screen surfaces (widget, shortcuts, deep
/// links, Quick Settings tile). Fast and never throws.
///
/// * Drains water taps the widget/tile queued while the app was not running.
/// * Handles the launch link and live `athleteos://open/...` links.
/// * Keeps the widget snapshot fresh (≤ 1 push / 15 s, only on change) and
///   flushes it when the app goes to the background.
/// * Recomputes the day's data at local midnight.
Future<void> surfacesBootstrap(ProviderContainer container) async {
  try {
    final platform = container.read(surfacesPlatformProvider);
    final drainer = container.read(waterQueueDrainerProvider);
    final sync = container.read(widgetSyncServiceProvider);
    final links = DeepLinkRouter(
      router: () => container.read(routerProvider),
      onAction: (a) => _runAction(a),
    );

    unawaited(_drain(drainer));

    await _eventsSub?.cancel();
    _eventsSub = platform.events.listen((e) {
      switch (e) {
        case SurfaceLinkEvent(:final uri):
          _safely(() => links.open(uri));
        case SurfaceWaterQueuedEvent():
          unawaited(_drain(drainer));
      }
    });

    unawaited(_openInitialLink(platform, links));

    _snapshotSub?.close();
    _snapshotSub = container.listen<WidgetSnapshot?>(
      widgetSnapshotProvider,
      (_, next) => sync.onSnapshot(next),
      fireImmediately: true,
    );

    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_drain(drainer)),
      onHide: sync.flush,
    );

    _scheduleMidnight(container);
  } catch (e) {
    debugPrint('surfaces bootstrap degraded: ${redactSecrets(e.toString())}');
  }
}

Future<void> _drain(WaterQueueDrainer drainer) async {
  try {
    await drainer.drain();
  } catch (e) {
    debugPrint('surface water drain failed: ${redactSecrets(e.toString())}');
  }
}

Future<void> _openInitialLink(
  SurfacesPlatform platform,
  DeepLinkRouter links,
) async {
  try {
    final link = await platform.getInitialLink().timeout(
      const Duration(seconds: 1),
    );
    if (link == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _safely(() => links.open(link)),
    );
  } catch (e) {
    debugPrint('surfaces initial link failed: ${redactSecrets(e.toString())}');
  }
}

void _runAction(DeepLinkAction action) {
  switch (action) {
    case DeepLinkAction.none:
      return;
    case DeepLinkAction.quickAddWater:
      // Wait for the pushed hydration route to build, then open the sheet.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          unawaited(showWaterQuickAddSheet(ctx));
        }
      });
  }
}

void _safely(void Function() f) {
  try {
    f();
  } catch (e) {
    debugPrint('surfaces link failed: ${redactSecrets(e.toString())}');
  }
}

/// At local midnight, recompute "today" so the widget never shows
/// yesterday's totals as today's (the native renderer also blanks values
/// whose date is not today).
void _scheduleMidnight(ProviderContainer container) {
  _midnight?.cancel();
  final now = container.read(clockProvider).now();
  final next = DateTime(now.year, now.month, now.day + 1, 0, 0, 5);
  _midnight = Timer(next.difference(now), () {
    container
      ..invalidate(todaySnapshotProvider)
      ..invalidate(todaysPlannedSessionProvider)
      ..invalidate(todaysRoutineProvider);
    _scheduleMidnight(container);
  });
}
