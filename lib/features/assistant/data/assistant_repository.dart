import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../domain/assistant_models.dart';
import '../domain/assistant_settings.dart';
import '../domain/hashing.dart';

/// All assistant persistence: settings (AppSettings `assistant.*`), per-app
/// settings, contact rules, captured notifications, drafts and the
/// content-free audit trail.
class AssistantRepository {
  AssistantRepository(this._db, this._settings, this._clock);
  final AppDatabase _db;
  final SettingsRepository _settings;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  // ---------------------------------------------------------------------------
  // Global settings
  // ---------------------------------------------------------------------------

  SimpleSelectStatement<$AppSettingsTable, AppSetting> get _settingsQuery =>
      _db.select(_db.appSettings)
        ..where((s) => s.key.like('${AssistantKeys.prefix}%'));

  static AssistantSettings _decode(List<AppSetting> rows) {
    final values = <String, Object?>{};
    for (final r in rows) {
      try {
        values[r.key] = jsonDecode(r.valueJson);
      } catch (_) {}
    }
    return AssistantSettings.fromValues(values);
  }

  Future<AssistantSettings> settings() async =>
      _decode(await _settingsQuery.get());

  Stream<AssistantSettings> watchSettings() =>
      _settingsQuery.watch().map(_decode);

  Future<void> setSetting(String key, Object? value) {
    assert(key.startsWith(AssistantKeys.prefix));
    return _settings.set(key, value);
  }

  Future<T?> getSetting<T>(String key) => _settings.get<T>(key);

  // ---------------------------------------------------------------------------
  // Per-app settings
  // ---------------------------------------------------------------------------

  Stream<List<MessagingAppSetting>> watchApps() => (_db.select(
    _db.messagingAppSettings,
  )..orderBy([(a) => OrderingTerm.asc(a.appLabel)])).watch();

  Future<List<MessagingAppSetting>> apps() =>
      _db.select(_db.messagingAppSettings).get();

  Future<MessagingAppSetting?> app(String packageName) => (_db.select(
    _db.messagingAppSettings,
  )..where((a) => a.packageName.equals(packageName))).getSingleOrNull();

  /// Creates or updates an app's settings. `autoSendBlocked` is always
  /// derived from code ([isAutoSendBlockedInCode]) and cannot be lifted.
  Future<void> upsertApp(
    String packageName, {
    required String appLabel,
    bool? enabled,
    AssistantMode? mode,
    bool? allowAi,
    int? retentionDays,
  }) async {
    final existing = await app(packageName);
    final blocked = isAutoSendBlockedInCode(packageName);
    var m = mode;
    if (m == AssistantMode.restrictedAuto && blocked) {
      m = AssistantMode.approval;
    }
    if (existing == null) {
      await _db
          .into(_db.messagingAppSettings)
          .insert(
            MessagingAppSettingsCompanion.insert(
              packageName: packageName,
              appLabel: appLabel,
              enabled: Value(enabled ?? false),
              mode: Value((m ?? AssistantMode.draft).key),
              allowAi: Value(allowAi ?? false),
              autoSendBlocked: Value(blocked),
              retentionDays: Value((retentionDays ?? 7).clamp(1, 90)),
              updatedAt: Value(_nowUtc),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      return;
    }
    await (_db.update(
      _db.messagingAppSettings,
    )..where((a) => a.packageName.equals(packageName))).write(
      MessagingAppSettingsCompanion(
        enabled: enabled == null ? const Value.absent() : Value(enabled),
        mode: m == null ? const Value.absent() : Value(m.key),
        allowAi: allowAi == null ? const Value.absent() : Value(allowAi),
        retentionDays: retentionDays == null
            ? const Value.absent()
            : Value(retentionDays.clamp(1, 90)),
        autoSendBlocked: Value(blocked),
        updatedAt: Value(_nowUtc),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Contact rules
  // ---------------------------------------------------------------------------

  Stream<List<MessagingContactRule>> watchContacts() => (_db.select(
    _db.messagingContactRules,
  )..orderBy([(c) => OrderingTerm.asc(c.displayName)])).watch();

  Future<MessagingContactRule?> contact(
    String packageName,
    String conversationKey,
  ) =>
      (_db.select(_db.messagingContactRules)..where(
            (c) =>
                c.packageName.equals(packageName) &
                c.conversationKey.equals(conversationKey),
          ))
          .getSingleOrNull();

  /// Ensures a (neutral) rule row exists so the conversation can be approved
  /// or blocked in settings.
  Future<MessagingContactRule> ensureContact({
    required String packageName,
    required String conversationKey,
    required String displayName,
    required bool isGroup,
    required String identityConfidence,
  }) async {
    final existing = await contact(packageName, conversationKey);
    if (existing != null) return existing;
    await _db
        .into(_db.messagingContactRules)
        .insert(
          MessagingContactRulesCompanion.insert(
            id: newId(),
            packageName: packageName,
            conversationKey: conversationKey,
            displayName: displayName,
            isGroup: Value(isGroup),
            identityConfidence: Value(identityConfidence),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (await contact(packageName, conversationKey))!;
  }

  Future<void> updateContact(
    String id, {
    String? rule,
    String? toneJson,
    bool clearTone = false,
    int? maxAutoRepliesPerDay,
  }) => (_db.update(_db.messagingContactRules)..where((c) => c.id.equals(id)))
      .write(
        MessagingContactRulesCompanion(
          rule: rule == null ? const Value.absent() : Value(rule),
          toneJson: clearTone
              ? const Value(null)
              : (toneJson == null ? const Value.absent() : Value(toneJson)),
          maxAutoRepliesPerDay: maxAutoRepliesPerDay == null
              ? const Value.absent()
              : Value(maxAutoRepliesPerDay.clamp(0, 20)),
          updatedAt: Value(_nowUtc),
        ),
      );

  // ---------------------------------------------------------------------------
  // Captured notifications
  // ---------------------------------------------------------------------------

  /// Inserts unless a row with the same dedupe hash exists. Returns whether
  /// a new row was written.
  Future<bool> insertCaptured(CapturedNotificationsCompanion row) =>
      _db.transaction(() async {
        final hash = row.dedupeHash.value;
        final exists = await (_db.select(
          _db.capturedNotifications,
        )..where((c) => c.dedupeHash.equals(hash))).getSingleOrNull();
        if (exists != null) return false;
        await _db
            .into(_db.capturedNotifications)
            .insert(row, mode: InsertMode.insertOrIgnore);
        return true;
      });

  Future<CapturedNotification?> captured(String id) => (_db.select(
    _db.capturedNotifications,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<int> capturedCount() async =>
      (await _db.select(_db.capturedNotifications).get()).length;

  /// Messages of one conversation still within retention, oldest first.
  Future<List<CapturedNotification>> conversation(
    String packageName,
    String? conversationKey, {
    int limit = 10,
  }) async {
    final rows =
        await (_db.select(_db.capturedNotifications)
              ..where(
                (c) =>
                    c.packageName.equals(packageName) &
                    (conversationKey == null
                        ? c.conversationKey.isNull()
                        : c.conversationKey.equals(conversationKey)) &
                    c.expiresAt.isBiggerThanValue(_nowUtc),
              )
              ..orderBy([(c) => OrderingTerm.desc(c.postedAt)])
              ..limit(limit))
            .get();
    return rows.reversed.toList();
  }

  Stream<List<CapturedNotification>> watchRecentCaptured({int limit = 200}) =>
      (_db.select(_db.capturedNotifications)
            ..where((c) => c.status.isNotIn([CaptureStatus.dismissed]))
            ..orderBy([(c) => OrderingTerm.desc(c.postedAt)])
            ..limit(limit))
          .watch();

  Future<void> setCapturedStatus(String id, String status) =>
      (_db.update(_db.capturedNotifications)..where((c) => c.id.equals(id)))
          .write(CapturedNotificationsCompanion(status: Value(status)));

  /// Deletes expired captured rows and blanks the text of drafts older than
  /// their app's retention. Returns the number of captured rows deleted.
  Future<int> purgeExpired() async {
    final now = _nowUtc;
    var deleted = await (_db.delete(
      _db.capturedNotifications,
    )..where((c) => c.expiresAt.isSmallerOrEqualValue(now))).go();
    final apps = {for (final a in await this.apps()) a.packageName: a};
    // `expiresAt` is fixed at capture time; a retention the user shortened
    // later must still apply to rows captured before the change.
    for (final a in apps.values) {
      final cutoff = now.subtract(Duration(days: a.retentionDays.clamp(1, 90)));
      deleted +=
          await (_db.delete(_db.capturedNotifications)..where(
                (c) =>
                    c.packageName.equals(a.packageName) &
                    c.postedAt.isSmallerOrEqualValue(cutoff),
              ))
              .go();
    }
    final drafts = await (_db.select(
      _db.replyDrafts,
    )..where((d) => d.draftText.equals('').not())).get();
    for (final d in drafts) {
      final days = apps[d.packageName]?.retentionDays ?? 7;
      if (now.difference(d.createdAt.toUtc()) < Duration(days: days)) continue;
      await (_db.update(
        _db.replyDrafts,
      )..where((r) => r.id.equals(d.id))).write(
        ReplyDraftsCompanion(
          draftText: const Value(''),
          status: DraftStatus.open.contains(d.status)
              ? const Value(DraftStatus.expired)
              : const Value.absent(),
        ),
      );
    }
    return deleted;
  }

  /// "Delete all captured messages": removes every captured row and the
  /// text of every draft (drafts keep status for the audit list).
  Future<void> deleteAllContent() => _db.transaction(() async {
    await _db.delete(_db.capturedNotifications).go();
    await (_db.update(_db.replyDrafts)
          ..where((d) => d.status.isIn(DraftStatus.open.toList())))
        .write(const ReplyDraftsCompanion(status: Value(DraftStatus.expired)));
    await _db
        .update(_db.replyDrafts)
        .write(const ReplyDraftsCompanion(draftText: Value('')));
  });

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  Future<ReplyDraft?> draft(String id) => (_db.select(
    _db.replyDrafts,
  )..where((d) => d.id.equals(id))).getSingleOrNull();

  Future<ReplyDraft?> openDraftFor(
    String packageName,
    String? conversationKey,
  ) =>
      (_db.select(_db.replyDrafts)
            ..where(
              (d) =>
                  d.packageName.equals(packageName) &
                  (conversationKey == null
                      ? d.conversationKey.isNull()
                      : d.conversationKey.equals(conversationKey)) &
                  d.status.isIn(DraftStatus.open.toList()),
            )
            ..orderBy([(d) => OrderingTerm.desc(d.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<ReplyDraft> createDraft({
    required CapturedNotification source,
    required String status,
    required String risk,
    String? riskFlags,
    String? sendPolicy,
    String text = '',
    String? category,
    double? confidence,
  }) async {
    final id = newId();
    await _db
        .into(_db.replyDrafts)
        .insert(
          ReplyDraftsCompanion.insert(
            id: id,
            notificationId: Value(source.id),
            packageName: source.packageName,
            conversationKey: Value(source.conversationKey),
            draftText: text,
            category: Value(category),
            confidence: Value(confidence),
            risk: Value(risk),
            riskFlags: Value(riskFlags),
            status: Value(status),
            sendPolicy: Value(sendPolicy),
            idempotencyKey: idempotencyKeyFor(source.dedupeHash, id),
            createdAt: Value(_nowUtc),
          ),
        );
    return (await draft(id))!;
  }

  /// Points an open draft at the newest message of its conversation and
  /// refreshes its risk.
  Future<void> attachToLatest(
    String draftId, {
    required String notificationId,
    required String risk,
    String? riskFlags,
    String? status,
  }) =>
      (_db.update(_db.replyDrafts)..where(
            (d) =>
                d.id.equals(draftId) & d.status.isIn(DraftStatus.open.toList()),
          ))
          .write(
            ReplyDraftsCompanion(
              notificationId: Value(notificationId),
              risk: Value(risk),
              riskFlags: Value(riskFlags),
              status: status == null ? const Value.absent() : Value(status),
            ),
          );

  /// Edits the text/AI fields of a draft that is still open.
  ///
  /// A user edit ([fromAi] false) always applies and clears `confidence`,
  /// which marks the text as user-authored ([ReplyDraftAuthorship]). An AI
  /// write ([fromAi] true) is compare-and-set in SQL so it can never clobber
  /// text the user typed, even if they saved it while the drafter was
  /// running: it applies only when the stored text is empty, is the AI's own
  /// earlier output (`confidence` set), or — for an explicit "Draft with AI"
  /// tap — is still exactly [replacing], the text the user asked to replace.
  Future<bool> updateDraftText(
    String id,
    String text, {
    String? category,
    double? confidence,
    bool fromAi = false,
    String? replacing,
  }) async {
    final n =
        await (_db.update(_db.replyDrafts)..where((d) {
              final open =
                  d.id.equals(id) & d.status.isIn(DraftStatus.open.toList());
              if (!fromAi) return open;
              var replaceable =
                  d.confidence.isNotNull() | d.draftText.trim().equals('');
              if (replacing != null) {
                replaceable = replaceable | d.draftText.equals(replacing);
              }
              return open & replaceable;
            }))
            .write(
              ReplyDraftsCompanion(
                draftText: Value(text),
                category: fromAi ? Value(category) : const Value.absent(),
                confidence: fromAi ? Value(confidence) : const Value(null),
              ),
            );
    return n == 1;
  }

  /// Guarded status change: only applied when the current status may move
  /// to [to] (compare-and-set). Returns whether it was applied.
  Future<bool> transition(
    String id,
    String to, {
    Set<String>? from,
    String? deliveryDetail,
    String? sendPolicy,
    bool decided = false,
    bool sent = false,
  }) async {
    final sources = (from ?? DraftStatus.sourcesOf(to)).where(
      (s) => DraftStatus.canTransition(s, to),
    );
    if (sources.isEmpty) return false;
    final n =
        await (_db.update(_db.replyDrafts)
              ..where((d) => d.id.equals(id) & d.status.isIn(sources.toList())))
            .write(
              ReplyDraftsCompanion(
                status: Value(to),
                deliveryDetail: deliveryDetail == null
                    ? const Value.absent()
                    : Value(deliveryDetail),
                sendPolicy: sendPolicy == null
                    ? const Value.absent()
                    : Value(sendPolicy),
                decidedAt: decided ? Value(_nowUtc) : const Value.absent(),
                sentAt: sent ? Value(_nowUtc) : const Value.absent(),
              ),
            );
    return n == 1;
  }

  Stream<List<ReplyDraft>> watchOpenDrafts() =>
      (_db.select(_db.replyDrafts)
            ..where((d) => d.status.isIn(DraftStatus.open.toList()))
            ..orderBy([(d) => OrderingTerm.desc(d.createdAt)]))
          .watch();

  Future<int> openDraftCount() async => (await (_db.select(
    _db.replyDrafts,
  )..where((d) => d.status.isIn(DraftStatus.open.toList()))).get()).length;

  /// Drafts that left the queue (sent, failed, unsupported, rejected...).
  Stream<List<ReplyDraft>> watchDecidedDrafts({int limit = 100}) =>
      (_db.select(_db.replyDrafts)
            ..where(
              (d) => d.status.isIn([
                DraftStatus.approved,
                DraftStatus.sending,
                DraftStatus.handedOff,
                DraftStatus.failed,
                DraftStatus.unsupported,
                DraftStatus.rejected,
              ]),
            )
            ..orderBy([(d) => OrderingTerm.desc(d.createdAt)])
            ..limit(limit))
          .watch();

  Future<List<ReplyDraft>> allDrafts() => _db.select(_db.replyDrafts).get();

  /// Auto-replies handed off since [sinceUtc] (overall and per conversation).
  Future<({int total, int conversation})> autoRepliesSince(
    DateTime sinceUtc, {
    required String packageName,
    required String? conversationKey,
  }) async {
    final rows =
        await (_db.select(_db.replyDrafts)..where(
              (d) =>
                  d.sendPolicy.equals('restricted_auto') &
                  d.status.equals(DraftStatus.handedOff) &
                  d.sentAt.isBiggerOrEqualValue(sinceUtc),
            ))
            .get();
    return (
      total: rows.length,
      conversation: rows
          .where(
            (r) =>
                r.packageName == packageName &&
                r.conversationKey == conversationKey,
          )
          .length,
    );
  }

  // ---------------------------------------------------------------------------
  // Audit (content-free)
  // ---------------------------------------------------------------------------

  /// Records an automation decision. [detail] must be metadata only
  /// (reasons, flags, codes). The conversation key is stored hashed.
  Future<void> audit(
    String action, {
    String? packageName,
    String? conversationKey,
    String? refId,
    String? detail,
  }) => _db
      .into(_db.automationAudit)
      .insert(
        AutomationAuditCompanion.insert(
          id: newId(),
          action: action,
          packageName: Value(packageName),
          conversationKey: Value(
            conversationKey == null ? null : conversationRef(conversationKey),
          ),
          refId: Value(refId),
          detail: Value(detail),
          createdAt: Value(_nowUtc),
        ),
      );

  Stream<List<AutomationAuditData>> watchAudit({int limit = 300}) =>
      (_db.select(_db.automationAudit)
            ..orderBy([(a) => OrderingTerm.desc(a.createdAt)])
            ..limit(limit))
          .watch();

  Future<List<AutomationAuditData>> auditRows() =>
      _db.select(_db.automationAudit).get();
}

/// Who wrote a draft's current text.
extension ReplyDraftAuthorship on ReplyDraft {
  /// Non-empty text with no AI confidence: typed or edited by the user
  /// (a user edit clears `confidence`; every AI write sets it). The assistant
  /// never replaces such text automatically.
  bool get isUserAuthored => draftText.trim().isNotEmpty && confidence == null;
}
