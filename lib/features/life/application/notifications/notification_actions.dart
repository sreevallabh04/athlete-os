import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../../core/time/clock.dart';
import '../../../../core/util/ids.dart';
import '../../../../core/util/redact.dart';
import '../../../../data/db/database.dart';
import '../../../../data/repositories/water_repository.dart';
import '../../domain/reminder_kinds.dart';
import 'notification_gateway.dart';

const waterActionAmountMl = 250;
const waterSnooze = Duration(minutes: 30);

/// Handles notification *action buttons* (not plain taps). Shared by the
/// background isolate entry point and tests.
///
/// * "Log 250 ml" inserts a water log with source `notification`. The row id
///   is derived from the notification id + payload, so a duplicated callback
///   for the same notification can never log twice.
/// * "Snooze 30 min" schedules a one-off copy of the water reminder.
Future<bool> handleNotificationAction(
  NotificationTap tap, {
  required AppDatabase db,
  required NotificationGateway gateway,
  Clock clock = const Clock(),
}) async {
  switch (tap.actionId) {
    case NotificationActionIds.logWater:
      await WaterRepository(db, clock).add(
        waterActionAmountMl,
        source: 'notification',
        id: stableId('notification_water', '${tap.id}|${tap.payload ?? ''}'),
      );
      return true;
    case NotificationActionIds.snoozeWater:
      final when = tz.TZDateTime.from(clock.now().add(waterSnooze), tz.UTC);
      await gateway.schedule(
        NotificationRequest(
          id: SpecialNotificationIds.waterSnooze,
          title: ReminderKind.water.title,
          body: ReminderKind.water.body,
          channel: ReminderKind.water.channel,
          payload: '{"k":"water","snooze":"${when.toIso8601String()}"}',
          waterActions: true,
        ),
        when,
        exact: false,
      );
      return true;
  }
  return false;
}

/// Entry point for notification actions that don't open the app. Runs in a
/// separate background isolate started by the plugin, so it opens its own
/// database connection and closes it when done.
///
/// Limits: Android may delay or drop this when the app is force-stopped or
/// heavily battery-restricted; the open app's screens refresh the next time
/// their data is queried.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(
  NotificationResponse response,
) async {
  final tap = NotificationTap(
    id: response.id,
    actionId: response.actionId,
    payload: response.payload,
  );
  if (tap.actionId == null) return;
  AppDatabase? db;
  try {
    DartPluginRegistrant.ensureInitialized();
    db = AppDatabase();
    await handleNotificationAction(
      tap,
      db: db,
      gateway: FlnNotificationGateway(),
    );
  } catch (e) {
    debugPrint('Notification action failed: ${redactSecrets(e.toString())}');
  } finally {
    await db?.close();
  }
}
