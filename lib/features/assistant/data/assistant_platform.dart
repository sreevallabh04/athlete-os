import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/assistant_models.dart';
import '../domain/safe_log.dart';

/// Result of handing a reply to the source app's notification reply action.
class SendReplyResult {
  const SendReplyResult({
    required this.status,
    required this.code,
    required this.detail,
  });

  /// handed_off | failed | unsupported
  final String status;

  /// handed_off | notification_gone | no_reply_action |
  /// listener_not_connected | pending_intent_cancelled | duplicate |
  /// send_error | platform_error | ...
  final String code;

  /// Human-readable, content-free.
  final String detail;

  bool get handedOff => status == 'handed_off';

  static SendReplyResult fromMap(Object? raw) {
    final m = raw is Map ? raw.cast<Object?, Object?>() : const {};
    return SendReplyResult(
      status: (m['status'] as String?) ?? 'failed',
      code: (m['code'] as String?) ?? 'unknown',
      detail: (m['detail'] as String?) ?? 'No result from the platform.',
    );
  }
}

class LaunchableApp {
  const LaunchableApp(this.packageName, this.label);
  final String packageName;
  final String label;
}

/// Config mirrored to native SharedPreferences for the listener.
class NativeAssistantConfig {
  const NativeAssistantConfig({
    required this.killSwitch,
    required this.enabledPackages,
    required this.retentionDays,
  });
  final bool killSwitch;
  final List<String> enabledPackages;
  final int retentionDays;

  String toJson() => jsonEncode({
    'killSwitch': killSwitch,
    'enabledPackages': enabledPackages,
    'retentionDays': retentionDays,
  });
}

/// Lock-screen visibility of a notification the assistant posts.
enum LockScreenVisibility {
  /// Whole notification visible on a secure lock screen (generic copy only).
  public,

  /// Only the generic public version is shown until the device is unlocked.
  private,
}

/// Generic lock-screen copy for assistant notifications whose real title/body
/// carry personal content (contact/app names, health numbers, schedule).
abstract final class AssistantLockScreenCopy {
  static const briefingTitle = 'JARVIS · Briefing ready';
  static const reviewTitle = 'JARVIS · Evening review ready';
  static const approvalTitle = 'JARVIS · New message to review';
  static const body = 'Unlock to view';
}

/// Payload from the share sheet / an assistant notification tap.
class ShareIntent {
  const ShareIntent.text(this.text) : route = null;
  const ShareIntent.route(this.route) : text = null;
  final String? text;
  final String? route;

  static ShareIntent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    if (type == 'share' && raw['text'] is String) {
      return ShareIntent.text(raw['text'] as String);
    }
    if (type == 'route' && raw['route'] is String) {
      return ShareIntent.route(raw['route'] as String);
    }
    return null;
  }
}

/// Native capabilities used by the assistant. All methods are safe to call
/// when the platform side is missing (tests, non-Android): they return a
/// conservative default instead of throwing.
abstract interface class AssistantPlatform {
  Future<bool> isListenerEnabled();
  Future<bool> isListenerConnected();
  Future<bool> openListenerSettings();
  Future<bool> setConfig(NativeAssistantConfig config);
  Future<List<CapturedEvent>> drainQueue();
  Future<void> clearQueue();

  /// Live captured notifications while the engine is attached.
  Stream<CapturedEvent> get events;
  Future<SendReplyResult> sendReply({
    required String notificationKey,
    required String text,
    required String idempotencyKey,
  });
  Future<bool> openApp(String packageName);
  Future<List<LaunchableApp>> listLaunchableApps();
  Future<bool> isIgnoringBatteryOptimizations();
  Future<bool> requestIgnoreBatteryOptimizations();
  Future<bool> openAppDetailsSettings();
  Future<bool> openNotificationSettings();
  Future<bool?> areNotificationsEnabled();
  Future<bool?> canScheduleExactAlarms();
  Future<bool> startAssistantService();
  Future<bool> stopAssistantService();
  Future<bool> isAssistantServiceRunning();

  /// Posts a briefing/approval notification. Private by default: on a secure
  /// lock screen Android shows only [publicTitle]/[publicBody] (defaults to
  /// "JARVIS" / [AssistantLockScreenCopy.body]); the real [title]/[body]
  /// appear once the device is unlocked.
  Future<bool> postNotification(
    int id,
    String title,
    String body, {
    LockScreenVisibility visibility = LockScreenVisibility.private,
    String? publicTitle,
    String? publicBody,
  });

  /// True once when the user tapped Stop on the Assistant mode notification
  /// since the last call (the native side cannot write app settings itself).
  Future<bool> consumeServiceStopRequest();
  Future<String?> openHealthConnectSettings();
  Future<ShareIntent?> getInitialShare();
  Stream<ShareIntent> get shareEvents;
}

class MethodChannelAssistantPlatform implements AssistantPlatform {
  MethodChannelAssistantPlatform();

  static const _channel = MethodChannel('athlete_os/assistant');
  static const _events = EventChannel('athlete_os/notifications/events');
  static const _share = MethodChannel('athlete_os/share');
  static const _shareEvents = EventChannel('athlete_os/share/events');

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } catch (e) {
      safeLog('platform_call_failed', {
        'action': method,
        'error': errorCode(e),
      });
      return null;
    }
  }

  Future<bool> _bool(String method, [Map<String, Object?>? args]) async =>
      (await _call<bool>(method, args)) ?? false;

  @override
  Future<bool> isListenerEnabled() => _bool('isListenerEnabled');

  @override
  Future<bool> isListenerConnected() => _bool('isListenerConnected');

  @override
  Future<bool> openListenerSettings() => _bool('openListenerSettings');

  @override
  Future<bool> setConfig(NativeAssistantConfig config) =>
      _bool('setConfig', {'json': config.toJson()});

  @override
  Future<List<CapturedEvent>> drainQueue() async {
    final raw = await _call<List<Object?>>('drainQueue');
    return [
      for (final line in raw ?? const <Object?>[])
        ?CapturedEvent.tryParse(line),
    ];
  }

  @override
  Future<void> clearQueue() => _call<bool>('clearQueue');

  Stream<CapturedEvent>? _eventStream;

  @override
  Stream<CapturedEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .handleError((Object e) {
        safeLog('event_stream_error', {'error': errorCode(e)});
      })
      .map(CapturedEvent.tryParse)
      .where((e) => e != null)
      .cast<CapturedEvent>()
      .asBroadcastStream();

  @override
  Future<SendReplyResult> sendReply({
    required String notificationKey,
    required String text,
    required String idempotencyKey,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('sendReply', {
        'notificationKey': notificationKey,
        'text': text,
        'idempotencyKey': idempotencyKey,
      });
      return SendReplyResult.fromMap(raw);
    } on MissingPluginException {
      return const SendReplyResult(
        status: 'unsupported',
        code: 'platform_unavailable',
        detail: 'Replying from notifications is only available on Android.',
      );
    } catch (e) {
      return SendReplyResult(
        status: 'failed',
        code: 'platform_error',
        detail: 'The platform reported an error (${errorCode(e)}).',
      );
    }
  }

  @override
  Future<bool> openApp(String packageName) =>
      _bool('openApp', {'packageName': packageName});

  @override
  Future<List<LaunchableApp>> listLaunchableApps() async {
    final raw = await _call<List<Object?>>('listLaunchableApps');
    return [
      for (final m in raw ?? const <Object?>[])
        if (m is Map && m['packageName'] is String)
          LaunchableApp(
            m['packageName'] as String,
            (m['label'] as String?) ?? m['packageName'] as String,
          ),
    ];
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      _bool('isIgnoringBatteryOptimizations');

  @override
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _bool('requestIgnoreBatteryOptimizations');

  @override
  Future<bool> openAppDetailsSettings() => _bool('openAppDetailsSettings');

  @override
  Future<bool> openNotificationSettings() => _bool('openNotificationSettings');

  @override
  Future<bool?> areNotificationsEnabled() =>
      _call<bool>('areNotificationsEnabled');

  @override
  Future<bool?> canScheduleExactAlarms() =>
      _call<bool>('canScheduleExactAlarms');

  @override
  Future<bool> startAssistantService() => _bool('startAssistantService');

  @override
  Future<bool> stopAssistantService() => _bool('stopAssistantService');

  @override
  Future<bool> isAssistantServiceRunning() =>
      _bool('isAssistantServiceRunning');

  @override
  Future<bool> postNotification(
    int id,
    String title,
    String body, {
    LockScreenVisibility visibility = LockScreenVisibility.private,
    String? publicTitle,
    String? publicBody,
  }) => _bool('postNotification', {
    'id': id,
    'title': title,
    'body': body,
    'visibility': visibility.name,
    'publicTitle': publicTitle,
    'publicBody': publicBody,
  });

  @override
  Future<bool> consumeServiceStopRequest() =>
      _bool('consumeServiceStopRequest');

  @override
  Future<String?> openHealthConnectSettings() =>
      _call<String>('openHealthConnectSettings');

  @override
  Future<ShareIntent?> getInitialShare() async {
    try {
      return ShareIntent.fromMap(
        await _share.invokeMethod<Object?>('getInitialShare'),
      );
    } catch (_) {
      return null;
    }
  }

  Stream<ShareIntent>? _shareStream;

  @override
  Stream<ShareIntent> get shareEvents => _shareStream ??= _shareEvents
      .receiveBroadcastStream()
      .handleError((Object e) {
        safeLog('share_stream_error', {'error': errorCode(e)});
      })
      .map(ShareIntent.fromMap)
      .where((e) => e != null)
      .cast<ShareIntent>()
      .asBroadcastStream();
}

final assistantPlatformProvider = Provider<AssistantPlatform>(
  (ref) => MethodChannelAssistantPlatform(),
);
