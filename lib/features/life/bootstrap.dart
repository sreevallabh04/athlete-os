import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../app/router.dart';
import '../../core/util/redact.dart';
import 'application/notifications/notification_gateway.dart';
import 'application/notifications/notification_providers.dart';

/// Start-up work for the life feature. Called once from [bootstrap] before the
/// first frame. Must be fast and must not throw.
///
/// * Loads timezone data and sets the device's IANA zone so zoned reminders
///   stay correct across DST.
/// * Initialises notifications + Android channels.
/// * Re-plans every reminder now and whenever prefs/habits/settings change
///   (debounced, idempotent).
Future<void> lifeBootstrap(ProviderContainer container) async {
  try {
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone().timeout(
        const Duration(milliseconds: 800),
      );
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Unknown zone: tz.local stays UTC. Reminders still fire, possibly at
      // shifted wall-clock times; documented in docs/NOTIFICATIONS.md.
    }

    final service = container.read(reminderServiceProvider);
    final ok = await service
        .init(onTap: (tap) => _openFromTap(container, tap))
        .timeout(const Duration(seconds: 2), onTimeout: () => false);
    if (!ok) return;

    final launch = await container
        .read(notificationGatewayProvider)
        .launchTap()
        .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
    if (launch != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openFromTap(container, launch),
      );
    }

    // Keeps the trigger alive for the app's lifetime; the first emission
    // performs the start-up reschedule (after the first frame).
    container.listen(
      reminderInputsChangedProvider,
      (_, _) => service.scheduleSoon(),
      fireImmediately: true,
    );
  } catch (e) {
    debugPrint('Life bootstrap degraded: ${redactSecrets(e.toString())}');
  }
}

void _openFromTap(ProviderContainer container, NotificationTap tap) {
  // Action buttons ("Log 250 ml", "Snooze") run in the background handler
  // without opening the app; only plain taps navigate.
  if (tap.actionId != null && tap.actionId!.isNotEmpty) return;
  final route = routeForPayload(tap.payload);
  if (route == null) return;
  try {
    final router = container.read(routerProvider);
    if (tabRootPaths.contains(route)) {
      router.go(route);
    } else {
      unawaited(router.push(route));
    }
  } catch (e) {
    debugPrint('Notification navigation failed: ${redactSecrets('$e')}');
  }
}
