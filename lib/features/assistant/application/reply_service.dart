import 'package:flutter/services.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../data/assistant_platform.dart';
import '../data/assistant_repository.dart';
import '../domain/assistant_models.dart';
import '../domain/assistant_settings.dart';
import '../domain/reply_policy_engine.dart';
import '../domain/safe_log.dart';
import '../domain/sensitivity_classifier.dart';
import 'reply_drafter.dart';

/// Outcome of a user/auto send attempt, for the UI.
class SendOutcome {
  const SendOutcome(this.status, this.message);

  /// handed_off | failed | unsupported | refused
  final String status;
  final String message;
  bool get ok => status == DraftStatus.handedOff;
}

/// Flags whose content is never sent to the AI backend.
const aiExcludedFlags = {
  SensitivityFlag.otp,
  SensitivityFlag.credentials,
  SensitivityFlag.crisis,
};

/// Drafting, approval, rejection and sending of replies. All sends go
/// through [AssistantPlatform.sendReply] and only for a draft the user
/// tapped Send on, or one the policy engine allowed for restricted auto-reply.
class ReplyService {
  ReplyService({
    required this.repo,
    required this.platform,
    required this.drafter,
    required this.clock,
    this.policy = const ReplyPolicyEngine(),
    this.retryDelay = const Duration(seconds: 2),
    Future<void> Function(String text)? copyToClipboard,
  }) : _copy =
           copyToClipboard ??
           ((t) => Clipboard.setData(ClipboardData(text: t)));

  final AssistantRepository repo;
  final AssistantPlatform platform;
  final ReplyDrafter drafter;
  final Clock clock;
  final ReplyPolicyEngine policy;
  final Duration retryDelay;
  final Future<void> Function(String text) _copy;

  /// Serialises "find the conversation's open draft, else create one" so
  /// concurrent callers (ingestion, a double-tapped "Draft" button, the
  /// summary card) can never create two open drafts for one conversation.
  Future<void> _draftLock = Future.value();

  Future<T> _withDraftLock<T>(Future<T> Function() body) {
    final run = _draftLock.then((_) => body());
    _draftLock = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// A send left in `sending` for longer than this was interrupted (process
  /// killed mid hand-off) and is closed as failed by [recoverInterruptedSends].
  static const interruptedSendAfter = Duration(minutes: 5);

  /// Whether [source]'s content may be given to the AI drafter.
  ({bool allowed, String? reason}) aiAllowed({
    required AssistantSettings settings,
    required MessagingAppSetting? app,
    required Set<SensitivityFlag> flags,
  }) {
    if (settings.killSwitch) {
      return (allowed: false, reason: 'Emergency stop is on.');
    }
    if (!drafter.isConfigured) {
      return (allowed: false, reason: aiUnavailableMessage);
    }
    if (!settings.aiConsent) {
      return (
        allowed: false,
        reason:
            'AI drafting is off (turn on AI consent in Assistant settings).',
      );
    }
    if (app == null || !app.allowAi) {
      return (allowed: false, reason: 'AI is not allowed for this app.');
    }
    if (flags.any(aiExcludedFlags.contains)) {
      return (
        allowed: false,
        reason:
            'Not sent to AI: looks like a code, credentials or an emergency. '
            'Please reply yourself.',
      );
    }
    return (allowed: true, reason: null);
  }

  /// Creates (or refreshes) the conversation's open draft for a newly
  /// captured message, drafts with AI when allowed, and auto-sends only when
  /// the policy engine says `auto_send_allowed`.
  Future<ReplyDraft?> prepareDraft({
    required CapturedNotification source,
    required PolicyDecision decision,
    required PolicyInput input,
    required AssistantSettings settings,
    required MessagingAppSetting app,
    required MessagingContactRule? contact,
    required SensitivityResult sensitivity,
  }) async {
    if (!decision.mayDraft) return null;
    final status = decision.action == PolicyAction.saveDraft
        ? DraftStatus.draft
        : DraftStatus.pendingApproval;
    final sendPolicy = switch (decision.effectiveMode) {
      AssistantMode.approval => 'approval',
      AssistantMode.restrictedAuto => 'approval',
      _ => 'manual',
    };

    final (draft, isNew) = await _withDraftLock(() async {
      final open = await repo.openDraftFor(
        source.packageName,
        source.conversationKey,
      );
      if (open == null) {
        final created = await repo.createDraft(
          source: source,
          status: status,
          risk: sensitivity.risk,
          riskFlags: sensitivity.csv,
          sendPolicy: sendPolicy,
        );
        return (created, true);
      }
      await repo.attachToLatest(
        open.id,
        notificationId: source.id,
        risk: sensitivity.risk,
        riskFlags: sensitivity.csv,
        status: status,
      );
      return (open, false);
    });
    await repo.setCapturedStatus(source.id, CaptureStatus.drafted);
    await repo.audit(
      AuditAction.draft,
      packageName: source.packageName,
      conversationKey: source.conversationKey,
      refId: draft.id,
      detail:
          '${isNew ? 'created' : 'refreshed'};'
          'decision=${decision.action.key};risk=${sensitivity.risk}'
          '${sensitivity.csv == null ? '' : ';flags=${sensitivity.csv}'}',
    );
    safeLog('draft_prepared', {
      'package': source.packageName,
      'decision': decision.action.key,
      'status': status,
    });

    final ai = aiAllowed(
      settings: settings,
      app: app,
      flags: sensitivity.flags,
    );
    DraftResult? result;
    if (ai.allowed) {
      result = await _runDrafter(
        draft.id,
        settings: settings,
        contact: contact,
      );
    }

    if (decision.effectiveMode == AssistantMode.restrictedAuto &&
        result != null &&
        result.available) {
      final sinceUtc = _localDayStartUtc();
      final counts = await repo.autoRepliesSince(
        sinceUtc,
        packageName: source.packageName,
        conversationKey: source.conversationKey,
      );
      final withDraft = PolicyInput(
        globalMode: input.globalMode,
        killSwitch: input.killSwitch,
        app: input.app,
        contact: input.contact,
        isGroup: input.isGroup,
        identityConfidence: input.identityConfidence,
        flags: input.flags,
        limits: input.limits,
        minuteOfDay: input.minuteOfDay,
        hasReplyAction: input.hasReplyAction,
        draft: DraftCandidate(
          text: result.text!,
          category: result.category,
          confidence: result.confidence,
          needsHuman: result.needsHumanReason != null,
        ),
        sentToday: counts.total,
        sentTodayForConversation: counts.conversation,
      );
      final finalDecision = policy.decide(withDraft);
      await repo.audit(
        AuditAction.classify,
        packageName: source.packageName,
        conversationKey: source.conversationKey,
        refId: draft.id,
        detail:
            'auto_check=${finalDecision.action.key};'
            'reasons=${finalDecision.reasons.join(',')}',
      );
      if (finalDecision.action == PolicyAction.autoSendAllowed) {
        await _send(draft.id, trigger: 'restricted_auto');
        return repo.draft(draft.id);
      }
    }

    if (isNew &&
        status == DraftStatus.pendingApproval &&
        settings.approvalNotifications) {
      // Content-free: never put message text in a notification. Even the
      // app name stays off the lock screen (private + generic public copy).
      await platform.postNotification(
        7300 + (draft.id.hashCode & 0xff),
        'Reply waiting for your approval',
        '${app.appLabel}: review the draft in Athlete OS',
        visibility: LockScreenVisibility.private,
        publicTitle: AssistantLockScreenCopy.approvalTitle,
        publicBody: AssistantLockScreenCopy.body,
      );
    }
    return repo.draft(draft.id);
  }

  /// Asks the drafter for a draft (user tapped "Draft with AI").
  Future<DraftResult> draftWithAi(String draftId) async {
    final draft = await repo.draft(draftId);
    if (draft == null) {
      return const DraftResult.unavailable('Draft not found.');
    }
    final settings = await repo.settings();
    final app = await repo.app(draft.packageName);
    final ai = aiAllowed(
      settings: settings,
      app: app,
      flags: SensitivityResult.parseCsv(draft.riskFlags),
    );
    if (!ai.allowed) return DraftResult.unavailable(ai.reason!);
    final contact = draft.conversationKey == null
        ? null
        : await repo.contact(draft.packageName, draft.conversationKey!);
    return _runDrafter(
      draftId,
      settings: settings,
      contact: contact,
      explicit: true,
    );
  }

  static const keptUserDraftMessage =
      'Kept your edited reply — the AI did not replace it.';

  Future<DraftRequest?> buildRequest(
    ReplyDraft draft, {
    required AssistantSettings settings,
    required MessagingContactRule? contact,
  }) async {
    final app = await repo.app(draft.packageName);
    // Only this conversation, only within the app's CURRENT retention, and
    // never a message the classifier flagged as OTP / credentials / crisis
    // (an earlier flagged message must not ride along with a later one).
    final retention = Duration(days: (app?.retentionDays ?? 7).clamp(1, 90));
    final oldest = clock.now().toUtc().subtract(retention);
    final msgs = [
      for (final m in await repo.conversation(
        draft.packageName,
        draft.conversationKey,
      ))
        if (!m.postedAt.toUtc().isBefore(oldest) &&
            !SensitivityResult.parseCsv(m.sensitivityFlags)
                .any(aiExcludedFlags.contains))
          m,
    ];
    if (msgs.isEmpty) return null;
    return DraftRequest(
      appLabel: app?.appLabel ?? draft.packageName,
      conversationTitle: msgs.last.conversationTitle,
      isGroup: msgs.last.isGroup,
      messages: [
        for (final m in msgs)
          DraftMessage(sender: m.sender, text: m.body, at: m.postedAt),
      ],
      tone: settings.tone,
      contactTone: ContactTone.parse(contact?.toneJson),
      maxLength: settings.limits.maxLength,
    );
  }

  /// Runs the AI drafter for [draftId]. Automatic runs ([explicit] false,
  /// a new message arrived) never touch a user-authored draft: the drafter is
  /// not even called. An explicit "Draft with AI" tap replaces the text the
  /// user saw, but not text they saved while the drafter was running.
  Future<DraftResult> _runDrafter(
    String draftId, {
    required AssistantSettings settings,
    required MessagingContactRule? contact,
    bool explicit = false,
  }) async {
    final draft = await repo.draft(draftId);
    if (draft == null) return const DraftResult.unavailable('Draft not found.');
    if (!explicit && draft.isUserAuthored) {
      await repo.audit(
        AuditAction.draft,
        packageName: draft.packageName,
        conversationKey: draft.conversationKey,
        refId: draftId,
        detail: 'ai_draft_skipped;user_edited',
      );
      return const DraftResult.unavailable(keptUserDraftMessage);
    }
    final request = await buildRequest(
      draft,
      settings: settings,
      contact: contact,
    );
    if (request == null) {
      return const DraftResult.unavailable(
        'The original messages have expired (retention).',
      );
    }
    DraftResult result;
    try {
      result = await drafter.draft(request);
    } catch (e) {
      safeLog('drafter_failed', {'error': errorCode(e)});
      result = DraftResult.unavailable('AI drafting failed (${errorCode(e)}).');
    }
    if (result.available) {
      final applied = await repo.updateDraftText(
        draftId,
        result.text!.trim(),
        category: result.category,
        confidence: result.confidence.clamp(0, 1).toDouble(),
        fromAi: true,
        replacing: explicit ? draft.draftText : null,
      );
      if (!applied) {
        // The user edited (or the draft left the open states) while the
        // drafter ran. Report "unavailable" so restricted auto-reply can never
        // go on to send the user's unsent text.
        await repo.audit(
          AuditAction.draft,
          packageName: draft.packageName,
          conversationKey: draft.conversationKey,
          refId: draftId,
          detail: 'ai_draft_discarded;user_edited_or_closed',
        );
        return const DraftResult.unavailable(keptUserDraftMessage);
      }
      await repo.audit(
        AuditAction.draft,
        packageName: draft.packageName,
        conversationKey: draft.conversationKey,
        refId: draftId,
        detail:
            'ai_draft;category=${result.category};'
            'confidence=${result.confidence.toStringAsFixed(2)}',
      );
    }
    return result;
  }

  /// Creates a manual draft for a captured message (user tapped "Draft").
  Future<ReplyDraft?> createManualDraft(String capturedId) async {
    final settings = await repo.settings();
    if (settings.killSwitch) return null;
    final c = await repo.captured(capturedId);
    if (c == null) return null;
    final flags = SensitivityResult(
      SensitivityResult.parseCsv(c.sensitivityFlags),
    );
    final (d, isNew) = await _withDraftLock(() async {
      final existing = await repo.openDraftFor(
        c.packageName,
        c.conversationKey,
      );
      if (existing != null) return (existing, false);
      final created = await repo.createDraft(
        source: c,
        status: DraftStatus.draft,
        risk: flags.risk,
        riskFlags: flags.csv,
        sendPolicy: 'manual',
      );
      return (created, true);
    });
    if (!isNew) return d;
    await repo.setCapturedStatus(c.id, CaptureStatus.drafted);
    await repo.audit(
      AuditAction.draft,
      packageName: c.packageName,
      conversationKey: c.conversationKey,
      refId: d.id,
      detail: 'manual',
    );
    return d;
  }

  Future<bool> editDraft(String id, String text) =>
      repo.updateDraftText(id, text);

  Future<void> reject(String id) async {
    final d = await repo.draft(id);
    if (d == null) return;
    final ok = await repo.transition(
      id,
      DraftStatus.rejected,
      decided: true,
      deliveryDetail: 'Rejected by you',
    );
    if (!ok) return;
    if (d.notificationId != null) {
      await repo.setCapturedStatus(d.notificationId!, CaptureStatus.dismissed);
    }
    await repo.audit(
      AuditAction.reject,
      packageName: d.packageName,
      conversationKey: d.conversationKey,
      refId: id,
    );
  }

  /// The user tapped Send on this specific draft.
  Future<SendOutcome> approveAndSend(String id) async {
    final d = await repo.draft(id);
    if (d == null) return const SendOutcome('refused', 'Draft not found.');
    if (d.draftText.trim().isEmpty) {
      return const SendOutcome('refused', 'Write a reply first.');
    }
    final settings = await repo.settings();
    if (settings.killSwitch) {
      return const SendOutcome(
        'refused',
        'Emergency stop is on — nothing can be sent.',
      );
    }
    final approved = await repo.transition(
      id,
      DraftStatus.approved,
      from: {DraftStatus.draft, DraftStatus.pendingApproval},
      decided: true,
      sendPolicy: d.sendPolicy == 'approval' ? 'approval' : 'manual',
    );
    if (!approved) {
      return SendOutcome(
        'refused',
        'This draft is already ${DraftStatus.label(d.status).toLowerCase()}.',
      );
    }
    await repo.audit(
      AuditAction.approve,
      packageName: d.packageName,
      conversationKey: d.conversationKey,
      refId: id,
    );
    return _send(id, trigger: 'user_tap');
  }

  /// No reply action (or user preference): copy the draft and open the app.
  Future<SendOutcome> copyAndOpen(String id) async {
    final d = await repo.draft(id);
    if (d == null) return const SendOutcome('refused', 'Draft not found.');
    final app = await repo.app(d.packageName);
    final label = app?.appLabel ?? d.packageName;
    if (d.draftText.trim().isNotEmpty) await _copy(d.draftText);
    final opened = await platform.openApp(d.packageName);
    final detail =
        'Copied to clipboard${opened ? ' and opened $label' : ''}; paste and '
        'send it yourself in $label (not tracked).';
    await repo.transition(
      id,
      DraftStatus.unsupported,
      decided: true,
      deliveryDetail: detail,
    );
    await repo.audit(
      AuditAction.send,
      packageName: d.packageName,
      conversationKey: d.conversationKey,
      refId: id,
      detail: 'copy_and_open;opened=$opened',
    );
    return SendOutcome(DraftStatus.unsupported, detail);
  }

  Future<SendOutcome> _send(String id, {required String trigger}) async {
    final d = await repo.draft(id);
    if (d == null) return const SendOutcome('refused', 'Draft not found.');
    final settings = await repo.settings();
    if (settings.killSwitch) {
      return const SendOutcome('refused', 'Emergency stop is on.');
    }
    if (trigger == 'restricted_auto' &&
        isAutoSendBlockedInCode(d.packageName)) {
      // Defence in depth: the policy engine already blocks this; an automated
      // send must never go out for a ToS-blocked / unverified app.
      await repo.audit(
        AuditAction.sendFailed,
        packageName: d.packageName,
        conversationKey: d.conversationKey,
        refId: id,
        detail: 'app_auto_send_blocked;trigger=$trigger',
      );
      return const SendOutcome(
        'refused',
        'This app does not allow automated replies.',
      );
    }
    final moved = await repo.transition(
      id,
      DraftStatus.sending,
      from: trigger == 'restricted_auto'
          ? DraftStatus.open
          : {DraftStatus.approved},
      sendPolicy: trigger == 'restricted_auto' ? 'restricted_auto' : null,
      decided: trigger == 'restricted_auto',
    );
    if (!moved) {
      return const SendOutcome(
        'refused',
        'This draft is no longer waiting to be sent.',
      );
    }
    final app = await repo.app(d.packageName);
    final label = app?.appLabel ?? d.packageName;
    final source = d.notificationId == null
        ? null
        : await repo.captured(d.notificationId!);
    if (source == null || !source.hasReplyAction) {
      final detail = source == null
          ? 'The original notification has expired. Use "Copy & open" to '
                'send it in $label yourself.'
          : '$label did not offer a reply action on this notification. Use '
                '"Copy & open" to send it yourself.';
      await repo.transition(
        id,
        DraftStatus.unsupported,
        from: {DraftStatus.sending},
        deliveryDetail: detail,
      );
      await repo.audit(
        AuditAction.sendFailed,
        packageName: d.packageName,
        conversationKey: d.conversationKey,
        refId: id,
        detail: 'no_reply_action;trigger=$trigger',
      );
      return SendOutcome(DraftStatus.unsupported, detail);
    }

    Future<SendReplyResult> attempt() async {
      try {
        return await platform.sendReply(
          notificationKey: source.notificationKey,
          text: d.draftText,
          idempotencyKey: d.idempotencyKey,
        );
      } catch (e) {
        // Never leave the draft stuck in `sending`; never mark it sent.
        return SendReplyResult(
          status: 'failed',
          code: 'send_error',
          detail: 'The platform reported an error (${errorCode(e)}).',
        );
      }
    }

    var result = await attempt();
    if (result.code == 'listener_not_connected') {
      // At most one retry, and only when nothing was handed off.
      await Future<void>.delayed(retryDelay);
      result = await attempt();
    }

    final to = switch (result.status) {
      'handed_off' => DraftStatus.handedOff,
      'unsupported' => DraftStatus.unsupported,
      _ => DraftStatus.failed,
    };
    final detail = to == DraftStatus.unsupported
        ? '${result.detail} Use "Copy & open" to send it yourself.'
        : result.detail;
    await repo.transition(
      id,
      to,
      from: {DraftStatus.sending},
      deliveryDetail: detail,
      sent: to == DraftStatus.handedOff,
    );
    if (to == DraftStatus.handedOff) {
      await repo.setCapturedStatus(source.id, CaptureStatus.replied);
    }
    await repo.audit(
      to == DraftStatus.handedOff ? AuditAction.send : AuditAction.sendFailed,
      packageName: d.packageName,
      conversationKey: d.conversationKey,
      refId: id,
      detail: 'code=${result.code};trigger=$trigger',
    );
    safeLog('send_result', {
      'package': d.packageName,
      'status': to,
      'code': result.code,
      'trigger': trigger,
    });
    return SendOutcome(to, detail);
  }

  /// Closes drafts left in `sending` by an interrupted hand-off (e.g. the
  /// process was killed between approval and the platform result) as
  /// `failed`. They are never retried automatically: the hand-off may or may
  /// not have happened. Returns how many were closed.
  Future<int> recoverInterruptedSends() async {
    final cutoff = clock.now().toUtc().subtract(interruptedSendAfter);
    var n = 0;
    for (final d in await repo.allDrafts()) {
      if (d.status != DraftStatus.sending) continue;
      final since = d.decidedAt ?? d.createdAt;
      if (since.toUtc().isAfter(cutoff)) continue;
      final ok = await repo.transition(
        d.id,
        DraftStatus.failed,
        from: {DraftStatus.sending},
        deliveryDetail:
            'The hand-off was interrupted; it may or may not have reached the '
            'app. Check the conversation before replying again.',
      );
      if (!ok) continue;
      n++;
      await repo.audit(
        AuditAction.sendFailed,
        packageName: d.packageName,
        conversationKey: d.conversationKey,
        refId: d.id,
        detail: 'interrupted',
      );
    }
    if (n > 0) safeLog('send_recovered', {'count': n});
    return n;
  }

  DateTime _localDayStartUtc() {
    final n = clock.now();
    final l = n.isUtc ? n.toLocal() : n;
    return DateTime(l.year, l.month, l.day).toUtc();
  }
}
