import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../domain/reminder_kinds.dart';

/// Action ids attached to water reminders.
abstract final class NotificationActionIds {
  static const logWater = 'water_log_250';
  static const snoozeWater = 'water_snooze_30';
}

/// Platform-neutral notification request.
class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.channel,
    this.payload,
    this.waterActions = false,
  });
  final int id;
  final String title;
  final String body;
  final ReminderChannel channel;
  final String? payload;

  /// Adds "Log 250 ml" and "Snooze 30 min" buttons.
  final bool waterActions;
}

/// A tap on a notification or one of its actions.
class NotificationTap {
  const NotificationTap({this.id, this.actionId, this.payload});
  final int? id;
  final String? actionId;
  final String? payload;
}

/// Thin seam over flutter_local_notifications so scheduling logic is
/// testable without platform channels.
abstract interface class NotificationGateway {
  /// Returns false when the platform plugin isn't available.
  Future<bool> initialize({required void Function(NotificationTap) onTap});
  Future<void> createChannels(List<ReminderChannel> channels);

  /// Null when unknown (e.g. unsupported platform).
  Future<bool?> notificationsEnabled();
  Future<bool> requestPermission();
  Future<bool?> canScheduleExact();
  Future<bool> requestExactAlarms();
  Future<void> show(NotificationRequest request);
  Future<void> schedule(
    NotificationRequest request,
    tz.TZDateTime when, {
    required bool exact,
  });
  Future<void> cancel(int id);
  Future<List<int>> pendingIds();
  Future<bool> openSystemSettings();

  /// The tap that launched the app from a terminated state, if any.
  Future<NotificationTap?> launchTap();
}

/// Top-level so it can be shared with the background isolate.
NotificationDetails notificationDetailsFor(NotificationRequest r) =>
    NotificationDetails(
      android: AndroidNotificationDetails(
        r.channel.id,
        r.channel.label,
        channelDescription: r.channel.description,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.reminder,
        styleInformation: BigTextStyleInformation(r.body),
        actions: r.waterActions
            ? const [
                AndroidNotificationAction(
                  NotificationActionIds.logWater,
                  'Log 250 ml',
                ),
                AndroidNotificationAction(
                  NotificationActionIds.snoozeWater,
                  'Snooze 30 min',
                ),
              ]
            : null,
      ),
    );

/// Production gateway backed by flutter_local_notifications (Android-first).
class FlnNotificationGateway implements NotificationGateway {
  FlnNotificationGateway({
    FlutterLocalNotificationsPlugin? plugin,
    this.backgroundHandler,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Must be a top-level `@pragma('vm:entry-point')` function.
  final DidReceiveBackgroundNotificationResponseCallback? backgroundHandler;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static NotificationTap _tap(NotificationResponse r) =>
      NotificationTap(id: r.id, actionId: r.actionId, payload: r.payload);

  @override
  Future<bool> initialize({
    required void Function(NotificationTap) onTap,
  }) async {
    if (!_isAndroid) return false;
    final ok = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
      ),
      onDidReceiveNotificationResponse: (r) => onTap(_tap(r)),
      onDidReceiveBackgroundNotificationResponse: backgroundHandler,
    );
    return ok ?? false;
  }

  @override
  Future<void> createChannels(List<ReminderChannel> channels) async {
    final android = _android;
    if (android == null) return;
    for (final c in channels) {
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          c.id,
          c.label,
          description: c.description,
          importance: Importance.defaultImportance,
        ),
      );
    }
  }

  @override
  Future<bool?> notificationsEnabled() async =>
      _android?.areNotificationsEnabled();

  @override
  Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? false;

  @override
  Future<bool?> canScheduleExact() async =>
      _android?.canScheduleExactNotifications();

  @override
  Future<bool> requestExactAlarms() async =>
      await _android?.requestExactAlarmsPermission() ?? false;

  @override
  Future<void> show(NotificationRequest request) async {
    if (!_isAndroid) return;
    await _plugin.show(
      id: request.id,
      title: request.title,
      body: request.body,
      notificationDetails: notificationDetailsFor(request),
      payload: request.payload,
    );
  }

  @override
  Future<void> schedule(
    NotificationRequest request,
    tz.TZDateTime when, {
    required bool exact,
  }) async {
    if (!_isAndroid) return;
    await _plugin.zonedSchedule(
      id: request.id,
      scheduledDate: when,
      notificationDetails: notificationDetailsFor(request),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      title: request.title,
      body: request.body,
      payload: request.payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    if (!_isAndroid) return;
    await _plugin.cancel(id: id);
  }

  @override
  Future<List<int>> pendingIds() async {
    if (!_isAndroid) return const [];
    final pending = await _plugin.pendingNotificationRequests();
    return [for (final p in pending) p.id];
  }

  @override
  Future<bool> openSystemSettings() async =>
      await _android?.openAppNotificationSettings() ?? false;

  @override
  Future<NotificationTap?> launchTap() async {
    if (!_isAndroid) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    final r = details?.notificationResponse;
    if (details?.didNotificationLaunchApp != true || r == null) return null;
    return _tap(r);
  }
}
