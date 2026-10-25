import 'dart:async';

import 'package:drift/drift.dart' show Value;

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../data/assistant_platform.dart';
import '../data/assistant_repository.dart';
import '../domain/assistant_models.dart';
import '../domain/hashing.dart';
import '../domain/reply_policy_engine.dart';
import '../domain/safe_log.dart';
import '../domain/sensitivity_classifier.dart';
import 'reply_service.dart';

enum IngestOutcome { stored, duplicate, ignored, killed }

class IngestSummary {
  int stored = 0;
  int duplicates = 0;
  int ignored = 0;
  int killed = 0;

  void add(IngestOutcome o) => switch (o) {
    IngestOutcome.stored => stored++,
    IngestOutcome.duplicate => duplicates++,
    IngestOutcome.ignored => ignored++,
    IngestOutcome.killed => killed++,
  };
}

/// Turns captured notifications into stored rows + drafts, applying the
/// kill switch, per-app settings, contact rules, the sensitivity classifier
/// and the policy engine. Duplicate events (same dedupe hash) are no-ops.
class IngestionService {
  IngestionService({
    required this.repo,
    required this.platform,
    required this.replies,
    required this.clock,
    this.classifier = const SensitivityClassifier(),
    this.policy = const ReplyPolicyEngine(),
  });

  final AssistantRepository repo;
  final AssistantPlatform platform;
  final ReplyService replies;
  final Clock clock;
  final SensitivityClassifier classifier;
  final ReplyPolicyEngine policy;

  StreamSubscription<CapturedEvent>? _sub;
  Timer? _drainDebounce;

  /// Serialises ingestion so concurrent drain/live events cannot race.
  Future<void> _chain = Future.value();

  Future<IngestSummary> ingest(Iterable<CapturedEvent> events) {
    final list = events.toList();
    final run = _chain.then((_) async {
      final summary = IngestSummary();
      for (final e in list) {
        try {
          summary.add(await _ingestOne(e));
        } catch (err) {
          safeLog('ingest_failed', {
            'package': e.packageName,
            'error': errorCode(err),
          });
        }
      }
      if (list.isNotEmpty) {
        safeLog('ingest', {
          'count': list.length,
          'inserted': summary.stored,
          'duplicates': summary.duplicates,
          'ignored': summary.ignored + summary.killed,
        });
      }
      return summary;
    });
    // A failed batch must never break the chain: every later `then` callback
    // would be skipped and ingestion would silently stop for the session.
    _chain = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<IngestSummary> drainAndIngest() async {
    final events = await platform.drainQueue();
    return ingest(events);
  }

  /// Subscribes to live events (idempotent). The native queue is drained a
  /// moment later so events delivered live are not kept on disk.
  void start() {
    _sub ??= platform.events.listen((e) {
      unawaited(ingest([e]));
      _drainDebounce?.cancel();
      _drainDebounce = Timer(const Duration(seconds: 3), () {
        unawaited(drainAndIngest().then((_) {}, onError: (_) {}));
      });
    });
  }

  Future<void> stop() async {
    _drainDebounce?.cancel();
    await _sub?.cancel();
    _sub = null;
  }

  Future<IngestOutcome> _ingestOne(CapturedEvent e) async {
    final settings = await repo.settings();
    if (settings.killSwitch || settings.mode == AssistantMode.disabled) {
      // Nothing is stored or audited per message while stopped.
      return IngestOutcome.killed;
    }
    final app = await repo.app(e.packageName);
    final contact = await repo.contact(e.packageName, e.conversationKey);
    // Once a conversation is known to be a group it stays one: a later
    // notification that omits the group flag must not turn it into a 1:1.
    final isGroup = e.isGroup || (contact?.isGroup ?? false);
    final sensitivity = classifier.classify(
      text: e.text,
      sender: e.sender ?? (isGroup ? null : e.title),
      isGroup: isGroup,
      identityConfidence: e.identityConfidence,
      contactKnown: contact?.rule == 'approved',
    );
    final now = clock.now();
    final local = now.isUtc ? now.toLocal() : now;
    final input = PolicyInput(
      globalMode: settings.mode,
      killSwitch: settings.killSwitch,
      app: app == null
          ? null
          : AppPolicy(
              packageName: app.packageName,
              enabled: app.enabled,
              mode: AssistantMode.fromKey(app.mode),
              autoSendBlocked: app.autoSendBlocked,
            ),
      contact: contact == null
          ? null
          : ContactPolicy(
              rule: contact.rule,
              identityConfidence: contact.identityConfidence,
              maxAutoRepliesPerDay: contact.maxAutoRepliesPerDay,
            ),
      isGroup: isGroup,
      identityConfidence: e.identityConfidence,
      flags: sensitivity.flags,
      limits: settings.limits,
      minuteOfDay: local.hour * 60 + local.minute,
      hasReplyAction: e.hasReplyAction,
    );
    final decision = policy.decide(input);

    if (decision.action == PolicyAction.ignore) {
      if (decision.reasons.contains('group_not_approved') && contact == null) {
        // Keep only the group's name (no message) so it can be approved in
        // settings.
        await repo.ensureContact(
          packageName: e.packageName,
          conversationKey: e.conversationKey,
          displayName: e.title ?? app?.appLabel ?? e.packageName,
          isGroup: true,
          identityConfidence: e.identityConfidence,
        );
      }
      await repo.audit(
        AuditAction.ignore,
        packageName: e.packageName,
        conversationKey: e.conversationKey,
        detail: 'reasons=${decision.reasons.join(',')}',
      );
      return IngestOutcome.ignored;
    }

    final hash =
        e.dedupeHash ??
        dedupeHashFor(
          packageName: e.packageName,
          conversationKey: e.conversationKey,
          text: e.text,
          postedAt: e.postedAt,
        );
    final retention = app!.retentionDays.clamp(1, 90);
    final id = newId();
    final inserted = await repo.insertCaptured(
      CapturedNotificationsCompanion.insert(
        id: id,
        dedupeHash: hash,
        notificationKey: e.notificationKey,
        packageName: e.packageName,
        conversationKey: Value(e.conversationKey),
        conversationTitle: Value(e.title),
        sender: Value(e.sender),
        isGroup: Value(isGroup),
        body: e.text,
        postedAt: e.postedAt.toUtc(),
        hasReplyAction: Value(e.hasReplyAction),
        sensitivityFlags: Value(sensitivity.csv),
        expiresAt: e.postedAt.toUtc().add(Duration(days: retention)),
        createdAt: Value(now.toUtc()),
      ),
    );
    if (!inserted) return IngestOutcome.duplicate;

    await repo.ensureContact(
      packageName: e.packageName,
      conversationKey: e.conversationKey,
      displayName: e.title ?? e.sender ?? app.appLabel,
      isGroup: isGroup,
      identityConfidence: e.identityConfidence,
    );
    await repo.audit(
      AuditAction.capture,
      packageName: e.packageName,
      conversationKey: e.conversationKey,
      refId: id,
      detail:
          'decision=${decision.action.key};risk=${sensitivity.risk}'
          '${sensitivity.csv == null ? '' : ';flags=${sensitivity.csv}'}'
          ';reply_action=${e.hasReplyAction}',
    );

    if (decision.mayDraft) {
      final source = await repo.captured(id);
      if (source != null) {
        await replies.prepareDraft(
          source: source,
          decision: decision,
          input: input,
          settings: settings,
          app: app,
          contact: contact,
          sensitivity: sensitivity,
        );
      }
    }
    return IngestOutcome.stored;
  }

  /// Retention purge (start-up and daily).
  Future<int> purge() async {
    final n = await repo.purgeExpired();
    if (n > 0) safeLog('retention_purge', {'count': n});
    return n;
  }
}
