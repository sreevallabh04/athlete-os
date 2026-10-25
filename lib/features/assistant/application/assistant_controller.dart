import '../../../data/db/database.dart';
import '../data/assistant_platform.dart';
import '../data/assistant_repository.dart';
import '../domain/assistant_models.dart';
import '../domain/assistant_settings.dart';
import '../domain/reply_policy_engine.dart';
import '../domain/safe_log.dart';

/// Settings mutations that must stay in sync with the native listener
/// (allowlist + kill switch) and the optional foreground service.
class AssistantController {
  AssistantController({required this.repo, required this.platform});
  final AssistantRepository repo;
  final AssistantPlatform platform;

  /// Writes the allowlist/kill switch to native SharedPreferences.
  Future<NativeAssistantConfig> syncNativeConfig() async {
    final s = await repo.settings();
    final apps = await repo.apps();
    final enabled = s.killSwitch || s.mode == AssistantMode.disabled
        ? <String>[]
        : [
            for (final a in apps)
              if (a.enabled && a.mode != AssistantMode.disabled.key)
                a.packageName,
          ];
    final cfg = NativeAssistantConfig(
      killSwitch: s.killSwitch,
      enabledPackages: enabled..sort(),
      retentionDays: s.defaultRetentionDays,
    );
    await platform.setConfig(cfg);
    safeLog('native_config', {
      'enabled': !s.killSwitch,
      'count': cfg.enabledPackages.length,
    });
    return cfg;
  }

  /// Emergency stop: no capture, no drafts, no sends, native listener told
  /// to ignore everything (and clear its queue), Assistant mode stopped.
  ///
  /// The setting is persisted first (Dart ingestion, drafting and sending
  /// honour it immediately). Every native step is then attempted even if an
  /// earlier one fails, and the first failure is rethrown afterwards so the
  /// UI can tell the user the stop was only partially applied.
  Future<void> setKillSwitch(bool on) async {
    await repo.setSetting(AssistantKeys.killSwitch, on);
    Object? firstError;
    StackTrace? firstStack;
    Future<void> step(String name, Future<void> Function() f) async {
      try {
        await f();
      } catch (e, st) {
        firstError ??= e;
        firstStack ??= st;
        safeLog('kill_switch_step_failed', {
          'action': name,
          'error': errorCode(e),
        });
      }
    }

    await step('sync_config', syncNativeConfig);
    if (on) {
      await step('stop_service', platform.stopAssistantService);
      await step('clear_queue', platform.clearQueue);
    } else {
      final s = await repo.settings();
      if (s.serviceEnabled) {
        await step('start_service', platform.startAssistantService);
      }
    }
    await repo.audit(
      AuditAction.killSwitch,
      detail: '${on ? 'on' : 'off'}${firstError == null ? '' : ';partial'}',
    );
    safeLog('kill_switch', {'enabled': on});
    final err = firstError;
    if (err != null) Error.throwWithStackTrace(err, firstStack!);
  }

  Future<void> setMode(AssistantMode mode) async {
    await repo.setSetting(AssistantKeys.mode, mode.key);
    await syncNativeConfig();
    await repo.audit(AuditAction.settings, detail: 'global_mode=${mode.key}');
  }

  Future<void> setAiConsent(bool on) async {
    await repo.setSetting(AssistantKeys.aiConsent, on);
    await repo.audit(AuditAction.settings, detail: 'ai_consent=$on');
  }

  Future<void> setLimits(PolicyLimits limits) async {
    await repo.setSetting(AssistantKeys.policy, policyLimitsToJson(limits));
    await repo.audit(AuditAction.settings, detail: 'limits_updated');
  }

  Future<void> setTone(ToneProfile tone) =>
      repo.setSetting(AssistantKeys.tone, tone.toJson());

  Future<void> setBriefing(BriefingSettings b) =>
      repo.setSetting(AssistantKeys.briefing, b.toJson());

  Future<void> setApprovalNotifications(bool on) =>
      repo.setSetting(AssistantKeys.approvalNotifications, on);

  Future<void> setDefaultRetention(int days) =>
      repo.setSetting(AssistantKeys.defaultRetentionDays, days.clamp(1, 90));

  /// Opt-in Assistant mode foreground service.
  Future<bool> setServiceEnabled(bool on) async {
    await repo.setSetting(AssistantKeys.serviceEnabled, on);
    final s = await repo.settings();
    final ok = on && !s.killSwitch
        ? await platform.startAssistantService()
        : await platform.stopAssistantService();
    await repo.audit(AuditAction.settings, detail: 'assistant_service=$on');
    return ok;
  }

  Future<void> updateApp(
    String packageName, {
    required String appLabel,
    bool? enabled,
    AssistantMode? mode,
    bool? allowAi,
    int? retentionDays,
  }) async {
    await repo.upsertApp(
      packageName,
      appLabel: appLabel,
      enabled: enabled,
      mode: mode,
      allowAi: allowAi,
      retentionDays: retentionDays,
    );
    await syncNativeConfig();
    await repo.audit(
      AuditAction.settings,
      packageName: packageName,
      detail: [
        if (enabled != null) 'enabled=$enabled',
        if (mode != null) 'mode=${mode.key}',
        if (allowAi != null) 'allow_ai=$allowAi',
        if (retentionDays != null) 'retention=$retentionDays',
      ].join(';'),
    );
  }

  Future<void> updateContact(
    MessagingContactRule c, {
    String? rule,
    String? toneJson,
    bool clearTone = false,
    int? maxAutoRepliesPerDay,
  }) async {
    await repo.updateContact(
      c.id,
      rule: rule,
      toneJson: toneJson,
      clearTone: clearTone,
      maxAutoRepliesPerDay: maxAutoRepliesPerDay,
    );
    await repo.audit(
      AuditAction.settings,
      packageName: c.packageName,
      conversationKey: c.conversationKey,
      detail: [
        if (rule != null) 'rule=$rule',
        if (toneJson != null || clearTone) 'tone_updated',
        if (maxAutoRepliesPerDay != null) 'max_auto=$maxAutoRepliesPerDay',
      ].join(';'),
    );
  }

  /// Deletes every captured message (DB + native queue) and draft text.
  Future<void> deleteAllCaptured() async {
    await repo.deleteAllContent();
    await platform.clearQueue();
    await repo.audit(AuditAction.settings, detail: 'deleted_all_captured');
    safeLog('deleted_all_captured');
  }
}
