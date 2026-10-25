import 'dart:convert';

import 'assistant_models.dart';
import 'reply_policy_engine.dart';

/// AppSettings keys owned by the assistant (all prefixed `assistant.`).
abstract final class AssistantKeys {
  static const prefix = 'assistant.';
  static const mode = 'assistant.mode';
  static const killSwitch = 'assistant.kill_switch';

  /// Whether captured message text may be sent to the AI backend at all
  /// (also requires the app's allowAi). Default false.
  static const aiConsent = 'assistant.ai_consent';
  static const policy = 'assistant.policy';
  static const tone = 'assistant.tone_profile';
  static const briefing = 'assistant.briefing';
  static const serviceEnabled = 'assistant.service_enabled';
  static const defaultRetentionDays = 'assistant.default_retention_days';
  static const lastMorningBriefing = 'assistant.briefing.last_morning';
  static const lastEveningReview = 'assistant.briefing.last_evening';
  static const approvalNotifications = 'assistant.approval_notifications';
}

/// User's writing style for drafts (global) — sent to the drafter only.
class ToneProfile {
  const ToneProfile({
    this.formality = 'neutral',
    this.brevity = 'short',
    this.emoji = 'some',
    this.languages = const ['English'],
    this.greetings = const [],
    this.signOffs = const [],
    this.avoidPhrases = const [],
    this.examples = const [],
  });

  /// casual | neutral | formal
  final String formality;

  /// short | medium | detailed
  final String brevity;

  /// none | some | lots
  final String emoji;
  final List<String> languages;
  final List<String> greetings;
  final List<String> signOffs;
  final List<String> avoidPhrases;

  /// User-provided example messages in their own voice.
  final List<String> examples;

  static List<String> _list(Object? v) => v is List
      ? v.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
      : const [];

  factory ToneProfile.fromJson(Map<String, dynamic> m) => ToneProfile(
    formality: m['formality'] as String? ?? 'neutral',
    brevity: m['brevity'] as String? ?? 'short',
    emoji: m['emoji'] as String? ?? 'some',
    languages: _list(m['languages']).isEmpty
        ? const ['English']
        : _list(m['languages']),
    greetings: _list(m['greetings']),
    signOffs: _list(m['signOffs']),
    avoidPhrases: _list(m['avoidPhrases']),
    examples: _list(m['examples']),
  );

  Map<String, dynamic> toJson() => {
    'formality': formality,
    'brevity': brevity,
    'emoji': emoji,
    'languages': languages,
    'greetings': greetings,
    'signOffs': signOffs,
    'avoidPhrases': avoidPhrases,
    'examples': examples,
  };

  ToneProfile copyWith({
    String? formality,
    String? brevity,
    String? emoji,
    List<String>? languages,
    List<String>? greetings,
    List<String>? signOffs,
    List<String>? avoidPhrases,
    List<String>? examples,
  }) => ToneProfile(
    formality: formality ?? this.formality,
    brevity: brevity ?? this.brevity,
    emoji: emoji ?? this.emoji,
    languages: languages ?? this.languages,
    greetings: greetings ?? this.greetings,
    signOffs: signOffs ?? this.signOffs,
    avoidPhrases: avoidPhrases ?? this.avoidPhrases,
    examples: examples ?? this.examples,
  );
}

/// Per-contact tone override (MessagingContactRules.toneJson).
class ContactTone {
  const ContactTone({this.formality, this.emoji, this.notes});
  final String? formality;
  final String? emoji;
  final String? notes;

  bool get isEmpty =>
      formality == null && emoji == null && (notes ?? '').trim().isEmpty;

  static ContactTone? parse(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final m = (jsonDecode(json) as Map).cast<String, dynamic>();
      return ContactTone(
        formality: m['formality'] as String?,
        emoji: m['emoji'] as String?,
        notes: m['notes'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode({
    if (formality != null) 'formality': formality,
    if (emoji != null) 'emoji': emoji,
    if ((notes ?? '').trim().isNotEmpty) 'notes': notes!.trim(),
  });
}

class BriefingSettings {
  const BriefingSettings({
    this.morningEnabled = false,
    this.morningMinutes = 7 * 60,
    this.eveningEnabled = false,
    this.eveningMinutes = 21 * 60,
  });
  final bool morningEnabled;
  final int morningMinutes;
  final bool eveningEnabled;
  final int eveningMinutes;

  factory BriefingSettings.fromJson(Map<String, dynamic> m) => BriefingSettings(
    morningEnabled: m['morningEnabled'] == true,
    morningMinutes: (m['morningMinutes'] as num?)?.toInt() ?? 7 * 60,
    eveningEnabled: m['eveningEnabled'] == true,
    eveningMinutes: (m['eveningMinutes'] as num?)?.toInt() ?? 21 * 60,
  );

  Map<String, dynamic> toJson() => {
    'morningEnabled': morningEnabled,
    'morningMinutes': morningMinutes,
    'eveningEnabled': eveningEnabled,
    'eveningMinutes': eveningMinutes,
  };

  BriefingSettings copyWith({
    bool? morningEnabled,
    int? morningMinutes,
    bool? eveningEnabled,
    int? eveningMinutes,
  }) => BriefingSettings(
    morningEnabled: morningEnabled ?? this.morningEnabled,
    morningMinutes: morningMinutes ?? this.morningMinutes,
    eveningEnabled: eveningEnabled ?? this.eveningEnabled,
    eveningMinutes: eveningMinutes ?? this.eveningMinutes,
  );
}

PolicyLimits policyLimitsFromJson(Map<String, dynamic> m) {
  const d = PolicyLimits();
  final cats = m['permittedCategories'];
  return PolicyLimits(
    permittedCategories: cats is List
        ? cats.whereType<String>().toSet()
        : d.permittedCategories,
    perConversationDailyCap:
        (m['perConversationDailyCap'] as num?)?.toInt() ??
        d.perConversationDailyCap,
    dailyCap: (m['dailyCap'] as num?)?.toInt() ?? d.dailyCap,
    confidenceThreshold:
        (m['confidenceThreshold'] as num?)?.toDouble() ?? d.confidenceThreshold,
    quietStartMinutes:
        (m['quietStartMinutes'] as num?)?.toInt() ?? d.quietStartMinutes,
    quietEndMinutes:
        (m['quietEndMinutes'] as num?)?.toInt() ?? d.quietEndMinutes,
    maxLength: (m['maxLength'] as num?)?.toInt() ?? d.maxLength,
  );
}

Map<String, dynamic> policyLimitsToJson(PolicyLimits l) => {
  'permittedCategories': l.permittedCategories.toList()..sort(),
  'perConversationDailyCap': l.perConversationDailyCap,
  'dailyCap': l.dailyCap,
  'confidenceThreshold': l.confidenceThreshold,
  'quietStartMinutes': l.quietStartMinutes,
  'quietEndMinutes': l.quietEndMinutes,
  'maxLength': l.maxLength,
};

/// All global assistant settings, read from AppSettings `assistant.*` keys.
class AssistantSettings {
  const AssistantSettings({
    this.mode = AssistantMode.draft,
    this.killSwitch = false,
    this.aiConsent = false,
    this.limits = const PolicyLimits(),
    this.tone = const ToneProfile(),
    this.briefing = const BriefingSettings(),
    this.serviceEnabled = false,
    this.defaultRetentionDays = 7,
    this.approvalNotifications = true,
  });

  final AssistantMode mode;
  final bool killSwitch;
  final bool aiConsent;
  final PolicyLimits limits;
  final ToneProfile tone;
  final BriefingSettings briefing;
  final bool serviceEnabled;
  final int defaultRetentionDays;
  final bool approvalNotifications;

  /// Builds settings from raw `key → decoded JSON value` pairs.
  factory AssistantSettings.fromValues(Map<String, Object?> v) {
    Map<String, dynamic> map(String k) => v[k] is Map
        ? (v[k] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return AssistantSettings(
      mode: AssistantMode.fromKey(v[AssistantKeys.mode] as String?),
      killSwitch: v[AssistantKeys.killSwitch] == true,
      aiConsent: v[AssistantKeys.aiConsent] == true,
      limits: policyLimitsFromJson(map(AssistantKeys.policy)),
      tone: ToneProfile.fromJson(map(AssistantKeys.tone)),
      briefing: BriefingSettings.fromJson(map(AssistantKeys.briefing)),
      serviceEnabled: v[AssistantKeys.serviceEnabled] == true,
      defaultRetentionDays:
          ((v[AssistantKeys.defaultRetentionDays] as num?)?.toInt() ?? 7).clamp(
            1,
            90,
          ),
      approvalNotifications: v[AssistantKeys.approvalNotifications] != false,
    );
  }
}
