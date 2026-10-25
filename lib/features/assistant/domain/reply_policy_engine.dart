import 'assistant_models.dart';
import 'sensitivity_classifier.dart';

/// What the assistant may do with one captured message. Ordered from least
/// to most automated.
enum PolicyAction {
  ignore('ignore'),
  observeOnly('observe_only'),
  saveDraft('save_draft'),
  requestApproval('request_approval'),
  autoSendAllowed('auto_send_allowed');

  const PolicyAction(this.key);
  final String key;
}

/// Per-app view needed by the policy (mirrors MessagingAppSettings).
class AppPolicy {
  const AppPolicy({
    required this.packageName,
    required this.enabled,
    required this.mode,
    required this.autoSendBlocked,
  });
  final String packageName;
  final bool enabled;
  final AssistantMode mode;
  final bool autoSendBlocked;
}

/// Per-conversation view (mirrors MessagingContactRules).
class ContactPolicy {
  const ContactPolicy({
    required this.rule,
    required this.identityConfidence,
    this.maxAutoRepliesPerDay = 0,
  });

  /// approved | blocked | neutral
  final String rule;
  final String identityConfidence;
  final int maxAutoRepliesPerDay;

  bool get approved => rule == 'approved';
  bool get blocked => rule == 'blocked';
}

/// A proposed reply, for the restricted auto-reply checks.
class DraftCandidate {
  const DraftCandidate({
    required this.text,
    required this.category,
    required this.confidence,
    this.needsHuman = false,
  });
  final String text;
  final String? category;
  final double? confidence;

  /// The drafter itself asked for a human (e.g. unclear request).
  final bool needsHuman;
}

/// Global limits for restricted auto-reply.
class PolicyLimits {
  const PolicyLimits({
    this.permittedCategories = const {ReplyCategory.acknowledgement},
    this.perConversationDailyCap = 2,
    this.dailyCap = 10,
    this.confidenceThreshold = 0.85,
    this.quietStartMinutes = 22 * 60,
    this.quietEndMinutes = 7 * 60,
    this.maxLength = 160,
  });

  final Set<String> permittedCategories;
  final int perConversationDailyCap;
  final int dailyCap;
  final double confidenceThreshold;

  /// Minutes after local midnight. Equal values = no quiet hours.
  final int quietStartMinutes;
  final int quietEndMinutes;
  final int maxLength;

  bool inQuietHours(int minuteOfDay) {
    final s = quietStartMinutes, e = quietEndMinutes;
    if (s == e) return false;
    if (s < e) return minuteOfDay >= s && minuteOfDay < e;
    return minuteOfDay >= s || minuteOfDay < e;
  }
}

class PolicyInput {
  const PolicyInput({
    required this.globalMode,
    required this.killSwitch,
    required this.app,
    required this.contact,
    required this.isGroup,
    required this.identityConfidence,
    required this.flags,
    required this.limits,
    required this.minuteOfDay,
    required this.hasReplyAction,
    this.draft,
    this.sentTodayForConversation = 0,
    this.sentToday = 0,
  });

  final AssistantMode globalMode;
  final bool killSwitch;
  final AppPolicy? app;
  final ContactPolicy? contact;
  final bool isGroup;
  final String identityConfidence;
  final Set<SensitivityFlag> flags;
  final PolicyLimits limits;
  final int minuteOfDay;
  final bool hasReplyAction;
  final DraftCandidate? draft;

  /// Auto-replies already handed off today (this conversation / overall).
  final int sentTodayForConversation;
  final int sentToday;
}

class PolicyDecision {
  const PolicyDecision(this.action, this.reasons, this.effectiveMode);
  final PolicyAction action;

  /// Machine-readable reasons (content-free), e.g. `contact_not_approved`.
  final List<String> reasons;
  final AssistantMode effectiveMode;

  bool get mayDraft =>
      action == PolicyAction.saveDraft ||
      action == PolicyAction.requestApproval ||
      action == PolicyAction.autoSendAllowed;

  @override
  String toString() => '${action.key}(${reasons.join(',')})';
}

/// All automation rules, enforced in code (never delegated to AI prompts).
///
/// Order: kill switch → global disabled → app enabled/mode → blocked contact
/// → group chats (ignored unless approved) → effective mode. Restricted
/// auto-reply requires EVERY condition below; any failure downgrades to
/// request_approval with the failing reasons.
class ReplyPolicyEngine {
  const ReplyPolicyEngine();

  PolicyDecision decide(PolicyInput i) {
    if (i.killSwitch) {
      return const PolicyDecision(PolicyAction.ignore, [
        'kill_switch',
      ], AssistantMode.disabled);
    }
    if (i.globalMode == AssistantMode.disabled) {
      return const PolicyDecision(PolicyAction.ignore, [
        'global_disabled',
      ], AssistantMode.disabled);
    }
    final app = i.app;
    if (app == null || !app.enabled) {
      return const PolicyDecision(PolicyAction.ignore, [
        'app_not_enabled',
      ], AssistantMode.disabled);
    }
    if (app.mode == AssistantMode.disabled) {
      return const PolicyDecision(PolicyAction.ignore, [
        'app_disabled',
      ], AssistantMode.disabled);
    }
    if (i.contact?.blocked ?? false) {
      return const PolicyDecision(PolicyAction.ignore, [
        'contact_blocked',
      ], AssistantMode.disabled);
    }
    if (i.isGroup && !(i.contact?.approved ?? false)) {
      return const PolicyDecision(PolicyAction.ignore, [
        'group_not_approved',
      ], AssistantMode.disabled);
    }

    final mode = i.globalMode.capBy(app.mode);
    switch (mode) {
      case AssistantMode.disabled:
        return PolicyDecision(PolicyAction.ignore, const ['disabled'], mode);
      case AssistantMode.observe:
        return PolicyDecision(PolicyAction.observeOnly, const [
          'observe_mode',
        ], mode);
      case AssistantMode.draft:
        return PolicyDecision(PolicyAction.saveDraft, const [
          'draft_mode',
        ], mode);
      case AssistantMode.approval:
        return PolicyDecision(PolicyAction.requestApproval, const [
          'approval_mode',
        ], mode);
      case AssistantMode.restrictedAuto:
        final blockers = autoSendBlockers(i);
        if (blockers.isEmpty) {
          return PolicyDecision(PolicyAction.autoSendAllowed, const [
            'all_auto_reply_conditions_met',
          ], mode);
        }
        return PolicyDecision(PolicyAction.requestApproval, blockers, mode);
    }
  }

  /// Every reason restricted auto-reply is not allowed (empty = allowed).
  List<String> autoSendBlockers(PolicyInput i) {
    final r = <String>[];
    final app = i.app;
    final l = i.limits;
    if (app == null ||
        app.autoSendBlocked ||
        isAutoSendBlockedInCode(app.packageName)) {
      r.add('app_auto_send_blocked');
    }
    final c = i.contact;
    if (c == null || !c.approved) r.add('contact_not_approved');
    final identity =
        c?.identityConfidence == 'high' && i.identityConfidence == 'high'
        ? 'high'
        : 'low';
    if (identity != 'high') r.add('low_identity_confidence');
    if (i.isGroup) r.add('group_chat');
    if (i.flags.isNotEmpty) {
      r.add(
        'sensitive:${(i.flags.map((f) => f.key).toList()..sort()).join('+')}',
      );
    }
    final d = i.draft;
    if (d == null || d.text.trim().isEmpty) {
      r.add('no_draft');
    } else {
      if (d.needsHuman) r.add('drafter_needs_human');
      if (d.category == null || !l.permittedCategories.contains(d.category)) {
        r.add('category_not_permitted');
      }
      if ((d.confidence ?? 0) < l.confidenceThreshold) {
        r.add('low_confidence');
      }
      if (d.text.length > l.maxLength) r.add('too_long');
    }
    final convCap = c == null
        ? 0
        : (c.maxAutoRepliesPerDay < l.perConversationDailyCap
              ? c.maxAutoRepliesPerDay
              : l.perConversationDailyCap);
    if (convCap <= 0 || i.sentTodayForConversation >= convCap) {
      r.add('conversation_cap_reached');
    }
    if (i.sentToday >= l.dailyCap) r.add('daily_cap_reached');
    if (l.inQuietHours(i.minuteOfDay)) r.add('quiet_hours');
    if (!i.hasReplyAction) r.add('no_reply_action');
    return r;
  }
}

/// Plain-language explanation of a policy reason for the UI.
String explainReason(String reason) {
  if (reason.startsWith('sensitive:')) {
    final keys = reason.substring('sensitive:'.length).split('+');
    final labels = [
      for (final k in keys) SensitivityFlag.fromKey(k)?.label ?? k,
    ];
    return 'Sensitive content (${labels.join(', ')}) always needs you.';
  }
  return switch (reason) {
    'kill_switch' => 'Emergency stop is on.',
    'global_disabled' => 'The assistant is disabled.',
    'app_not_enabled' => 'This app is not enabled.',
    'app_disabled' => 'This app is set to Disabled.',
    'contact_blocked' => 'This conversation is blocked.',
    'group_not_approved' => 'Group chats are ignored unless approved.',
    'observe_mode' => 'Observe mode: summaries only.',
    'draft_mode' => 'Draft mode: nothing is sent without your tap.',
    'approval_mode' => 'Approval mode: sent only when you tap Send.',
    'app_auto_send_blocked' => 'This app does not allow automated replies.',
    'contact_not_approved' => 'Contact is not approved for auto-replies.',
    'low_identity_confidence' => 'Contact could not be identified reliably.',
    'group_chat' => 'Group chats are never auto-replied.',
    'no_draft' => 'No draft yet.',
    'drafter_needs_human' => 'The drafter flagged this for you.',
    'category_not_permitted' => 'Reply type is not in your permitted list.',
    'low_confidence' => 'Draft confidence is below your threshold.',
    'too_long' => 'Draft is longer than your maximum.',
    'conversation_cap_reached' => 'Daily auto-reply limit for this chat.',
    'daily_cap_reached' => 'Daily auto-reply limit reached.',
    'quiet_hours' => 'Quiet hours.',
    'no_reply_action' => 'The notification has no reply action.',
    _ => reason,
  };
}
