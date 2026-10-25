import 'dart:convert';

/// Automation level. Ordered from least to most automated; the effective
/// mode for a message is the LOWER of the global mode and the app's mode.
enum AssistantMode {
  disabled('disabled', 'Disabled'),
  observe('observe', 'Observe'),
  draft('draft', 'Draft'),
  approval('approval', 'Approval'),
  restrictedAuto('restricted_auto', 'Restricted auto-reply');

  const AssistantMode(this.key, this.label);
  final String key;
  final String label;

  static AssistantMode fromKey(String? key, {AssistantMode? fallback}) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return fallback ?? AssistantMode.draft;
  }

  /// The more restrictive of two modes.
  AssistantMode capBy(AssistantMode other) =>
      index <= other.index ? this : other;

  String get description => switch (this) {
    AssistantMode.disabled => 'Nothing is read, stored or drafted.',
    AssistantMode.observe =>
      'Captures messages and shows summaries. No drafts, no sending.',
    AssistantMode.draft =>
      'Prepares reply drafts. Nothing is sent unless you tap Send.',
    AssistantMode.approval =>
      'Prepares drafts and notifies you to approve. Sends only when you tap '
          'Send.',
    AssistantMode.restrictedAuto =>
      'May send low-risk replies to approved contacts in apps that allow it '
          '(never WhatsApp). Everything else needs your approval.',
  };
}

/// ReplyDrafts.status values and the allowed transitions between them.
abstract final class DraftStatus {
  static const draft = 'draft';
  static const pendingApproval = 'pending_approval';
  static const approved = 'approved';
  static const sending = 'sending';
  static const handedOff = 'handed_off';
  static const failed = 'failed';
  static const rejected = 'rejected';
  static const expired = 'expired';
  static const unsupported = 'unsupported';

  /// Drafts still waiting for the user.
  static const open = {draft, pendingApproval};

  static const transitions = <String, Set<String>>{
    draft: {pendingApproval, approved, sending, rejected, expired, unsupported},
    pendingApproval: {draft, approved, sending, rejected, expired, unsupported},
    approved: {sending, rejected, expired, unsupported},
    sending: {handedOff, failed, unsupported},
    handedOff: {},
    failed: {expired},
    rejected: {expired},
    expired: {},
    unsupported: {expired},
  };

  static bool canTransition(String from, String to) =>
      transitions[from]?.contains(to) ?? false;

  /// Sources from which [to] may be reached.
  static Set<String> sourcesOf(String to) => {
    for (final e in transitions.entries)
      if (e.value.contains(to)) e.key,
  };

  static String label(String s) => switch (s) {
    draft => 'Draft',
    pendingApproval => 'Needs approval',
    approved => 'Approved',
    sending => 'Handing off…',
    handedOff => 'Handed off',
    failed => 'Failed',
    rejected => 'Rejected',
    expired => 'Expired',
    unsupported => 'Not sendable here',
    _ => s,
  };
}

/// CapturedNotifications.status values.
abstract final class CaptureStatus {
  static const fresh = 'new';
  static const ignored = 'ignored';
  static const summarized = 'summarized';
  static const drafted = 'drafted';
  static const replied = 'replied';
  static const dismissed = 'dismissed';
}

/// AutomationAudit.action values.
abstract final class AuditAction {
  static const capture = 'capture';
  static const ignore = 'ignore';
  static const classify = 'classify';
  static const draft = 'draft';
  static const approve = 'approve';
  static const reject = 'reject';
  static const send = 'send';
  static const sendFailed = 'send_failed';
  static const killSwitch = 'kill_switch';
  static const settings = 'settings';
}

/// Reply categories a drafter may assign. Restricted auto-reply only ever
/// sends categories the user permitted.
abstract final class ReplyCategory {
  static const acknowledgement = 'acknowledgement';
  static const availability = 'availability';
  static const scheduling = 'scheduling';
  static const logistics = 'logistics';
  static const social = 'social';
  static const question = 'question';
  static const other = 'other';

  static const all = [
    acknowledgement,
    availability,
    scheduling,
    logistics,
    social,
    question,
    other,
  ];

  static String label(String c) => switch (c) {
    acknowledgement => 'Acknowledgements ("Got it, thanks")',
    availability => 'Availability ("Busy now, will call later")',
    scheduling => 'Scheduling',
    logistics => 'Logistics',
    social => 'Social chit-chat',
    question => 'Answering questions',
    _ => 'Other',
  };
}

/// Auto-send policy of a messaging app, decided in code (not by settings).
enum AutoSendPolicy {
  /// Terms of service prohibit automated messaging. Never auto-send.
  tosBlocked,

  /// Terms not verified for automated replies. Auto-send blocked.
  unverified,

  /// Plain SMS/RCS apps: restricted auto-reply may be enabled by the user.
  permitted,
}

class KnownMessagingApp {
  const KnownMessagingApp(
    this.packageName,
    this.label,
    this.policy, {
    required this.note,
  });
  final String packageName;
  final String label;
  final AutoSendPolicy policy;
  final String note;
}

const whatsappTosNote =
    "WhatsApp's Terms of Service prohibit auto-messaging and accessing the "
    'service through automated means. The WhatsApp Business Platform cannot '
    'be attached to a personal account. So for WhatsApp the assistant only '
    'observes and drafts; a reply is sent only when you tap Send on a '
    "specific draft, using the notification's own Reply action.";

const unverifiedNote =
    "We could not verify that this app's terms allow automated replies, so "
    'auto-reply is blocked. Drafts and one-tap Send still work.';

const knownMessagingApps = <KnownMessagingApp>[
  KnownMessagingApp(
    'com.whatsapp',
    'WhatsApp',
    AutoSendPolicy.tosBlocked,
    note: whatsappTosNote,
  ),
  KnownMessagingApp(
    'com.whatsapp.w4b',
    'WhatsApp Business',
    AutoSendPolicy.tosBlocked,
    note: whatsappTosNote,
  ),
  KnownMessagingApp(
    'com.google.android.apps.messaging',
    'Google Messages',
    AutoSendPolicy.permitted,
    note:
        'SMS/RCS. Restricted auto-reply may be enabled for approved '
        'contacts, subject to every safety rule.',
  ),
  KnownMessagingApp(
    'com.android.mms',
    'Messages (SMS)',
    AutoSendPolicy.permitted,
    note: 'SMS. Restricted auto-reply may be enabled for approved contacts.',
  ),
  KnownMessagingApp(
    'org.telegram.messenger',
    'Telegram',
    AutoSendPolicy.unverified,
    note: unverifiedNote,
  ),
  KnownMessagingApp(
    'org.thoughtcrime.securesms',
    'Signal',
    AutoSendPolicy.unverified,
    note: unverifiedNote,
  ),
  KnownMessagingApp(
    'com.google.android.gm',
    'Gmail',
    AutoSendPolicy.unverified,
    note: unverifiedNote,
  ),
  KnownMessagingApp(
    'com.Slack',
    'Slack',
    AutoSendPolicy.unverified,
    note: unverifiedNote,
  ),
  KnownMessagingApp(
    'com.instagram.android',
    'Instagram',
    AutoSendPolicy.unverified,
    note: unverifiedNote,
  ),
];

KnownMessagingApp? knownApp(String packageName) {
  for (final a in knownMessagingApps) {
    if (a.packageName == packageName) return a;
  }
  return null;
}

/// Auto-send policy for any package: unknown apps are treated as unverified.
AutoSendPolicy autoSendPolicyFor(String packageName) =>
    knownApp(packageName)?.policy ?? AutoSendPolicy.unverified;

/// Hard, code-level block. Cannot be changed by settings.
bool isAutoSendBlockedInCode(String packageName) =>
    autoSendPolicyFor(packageName) != AutoSendPolicy.permitted;

/// A notification captured by the native listener.
class CapturedEvent {
  const CapturedEvent({
    required this.notificationKey,
    required this.packageName,
    required this.conversationKey,
    required this.identityConfidence,
    required this.text,
    required this.postedAt,
    this.title,
    this.sender,
    this.isGroup = false,
    this.hasReplyAction = false,
    this.dedupeHash,
  });

  final String notificationKey;
  final String packageName;
  final String conversationKey;

  /// 'high' (shortcut/locus id) | 'low' (title only)
  final String identityConfidence;
  final String? title;
  final String? sender;
  final bool isGroup;
  final String text;
  final DateTime postedAt;
  final bool hasReplyAction;
  final String? dedupeHash;

  /// Parses one native JSON line. Returns null for malformed input.
  static CapturedEvent? tryParse(Object? raw) {
    try {
      final Map<String, dynamic> m = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      final pkg = m['packageName'] as String?;
      final text = m['text'] as String?;
      final key = m['key'] as String?;
      if (pkg == null || text == null || key == null || text.trim().isEmpty) {
        return null;
      }
      final title = m['title'] as String?;
      return CapturedEvent(
        notificationKey: key,
        packageName: pkg,
        conversationKey:
            (m['conversationKey'] as String?) ?? 'title:${title ?? 'unknown'}',
        identityConfidence: m['identityConfidence'] == 'high' ? 'high' : 'low',
        title: title,
        sender: m['sender'] as String?,
        isGroup: m['isGroup'] == true,
        text: text,
        postedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['postTime'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        hasReplyAction: m['hasReplyAction'] == true,
        dedupeHash: m['dedupeHash'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
