import 'dart:async';

import '../domain/assistant_models.dart';
import 'assistant_platform.dart';

/// In-memory [AssistantPlatform] for tests and previews. Records every call.
class FakeAssistantPlatform implements AssistantPlatform {
  FakeAssistantPlatform({
    this.listenerEnabled = false,
    this.listenerConnected = false,
    this.batteryIgnored = false,
    this.notificationsEnabled = true,
    this.exactAlarms = true,
    List<LaunchableApp>? apps,
  }) : apps = apps ?? const [];

  bool listenerEnabled;
  bool listenerConnected;
  bool batteryIgnored;
  bool? notificationsEnabled;
  bool? exactAlarms;
  bool serviceRunning = false;
  List<LaunchableApp> apps;

  /// Results returned by successive [sendReply] calls (last one repeats).
  final List<SendReplyResult> sendResults = [];

  final List<({String key, String text, String idempotencyKey})> sendCalls = [];
  final List<NativeAssistantConfig> configs = [];
  final List<String> openedApps = [];
  final List<
    ({
      int id,
      String title,
      String body,
      LockScreenVisibility visibility,
      String? publicTitle,
      String? publicBody,
    })
  >
  posted = [];

  /// Simulates the user tapping Stop on the Assistant mode notification.
  bool serviceStopRequested = false;
  final List<CapturedEvent> queue = [];
  int openListenerSettingsCalls = 0;
  int requestBatteryCalls = 0;
  int openAppDetailsCalls = 0;
  int clearQueueCalls = 0;
  final Set<String> _usedKeys = {};

  final _events = StreamController<CapturedEvent>.broadcast();
  final _share = StreamController<ShareIntent>.broadcast();
  ShareIntent? initialShare;

  void emit(CapturedEvent e) => _events.add(e);
  void emitShare(ShareIntent s) => _share.add(s);

  NativeAssistantConfig? get lastConfig =>
      configs.isEmpty ? null : configs.last;

  @override
  Future<bool> isListenerEnabled() async => listenerEnabled;

  @override
  Future<bool> isListenerConnected() async => listenerConnected;

  @override
  Future<bool> openListenerSettings() async {
    openListenerSettingsCalls++;
    return true;
  }

  @override
  Future<bool> setConfig(NativeAssistantConfig config) async {
    configs.add(config);
    if (config.killSwitch) queue.clear();
    return true;
  }

  @override
  Future<List<CapturedEvent>> drainQueue() async {
    final out = List<CapturedEvent>.of(queue);
    queue.clear();
    return out;
  }

  @override
  Future<void> clearQueue() async {
    clearQueueCalls++;
    queue.clear();
  }

  @override
  Stream<CapturedEvent> get events => _events.stream;

  @override
  Future<SendReplyResult> sendReply({
    required String notificationKey,
    required String text,
    required String idempotencyKey,
  }) async {
    sendCalls.add((
      key: notificationKey,
      text: text,
      idempotencyKey: idempotencyKey,
    ));
    if (_usedKeys.contains(idempotencyKey)) {
      return const SendReplyResult(
        status: 'failed',
        code: 'duplicate',
        detail: 'This reply was already handed off once.',
      );
    }
    final r = sendResults.isEmpty
        ? const SendReplyResult(
            status: 'handed_off',
            code: 'handed_off',
            detail:
                "Handed to Fake's reply action; the app does not confirm "
                'delivery',
          )
        : (sendResults.length == 1
              ? sendResults.first
              : sendResults.removeAt(0));
    if (r.handedOff) _usedKeys.add(idempotencyKey);
    return r;
  }

  @override
  Future<bool> openApp(String packageName) async {
    openedApps.add(packageName);
    return true;
  }

  @override
  Future<List<LaunchableApp>> listLaunchableApps() async => apps;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => batteryIgnored;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    requestBatteryCalls++;
    return true;
  }

  @override
  Future<bool> openAppDetailsSettings() async {
    openAppDetailsCalls++;
    return true;
  }

  @override
  Future<bool> openNotificationSettings() async => true;

  @override
  Future<bool?> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<bool?> canScheduleExactAlarms() async => exactAlarms;

  @override
  Future<bool> startAssistantService() async => serviceRunning = true;

  @override
  Future<bool> stopAssistantService() async {
    serviceRunning = false;
    return true;
  }

  @override
  Future<bool> isAssistantServiceRunning() async => serviceRunning;

  @override
  Future<bool> postNotification(
    int id,
    String title,
    String body, {
    LockScreenVisibility visibility = LockScreenVisibility.private,
    String? publicTitle,
    String? publicBody,
  }) async {
    posted.add((
      id: id,
      title: title,
      body: body,
      visibility: visibility,
      publicTitle: publicTitle,
      publicBody: publicBody,
    ));
    return true;
  }

  /// Taps Stop on the (fake) Assistant mode notification.
  void tapServiceStop() {
    serviceRunning = false;
    serviceStopRequested = true;
  }

  @override
  Future<bool> consumeServiceStopRequest() async {
    final r = serviceStopRequested;
    serviceStopRequested = false;
    return r;
  }

  @override
  Future<String?> openHealthConnectSettings() async => 'hc_settings_action';

  @override
  Future<ShareIntent?> getInitialShare() async {
    final s = initialShare;
    initialShare = null;
    return s;
  }

  @override
  Stream<ShareIntent> get shareEvents => _share.stream;

  Future<void> dispose() async {
    await _events.close();
    await _share.close();
  }
}
