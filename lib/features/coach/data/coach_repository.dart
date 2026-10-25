import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';

/// Persistence for coach conversations, memories, recommendations and the
/// tool audit log (all local Drift tables).
class CoachRepository {
  CoachRepository(this._db);
  final AppDatabase _db;

  // -- Conversations ---------------------------------------------------------

  Stream<List<AiConversation>> watchConversations() => (_db.select(
    _db.aiConversations,
  )..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])).watch();

  Future<String> createConversation({String? title}) async {
    final id = newId();
    await _db
        .into(_db.aiConversations)
        .insert(AiConversationsCompanion.insert(id: id, title: Value(title)));
    return id;
  }

  Future<void> touchConversation(String id, {String? title}) =>
      (_db.update(_db.aiConversations)..where((c) => c.id.equals(id))).write(
        AiConversationsCompanion(
          updatedAt: Value(DateTime.now().toUtc()),
          title: title == null ? const Value.absent() : Value(title),
        ),
      );

  Future<AiConversation?> conversation(String id) => (_db.select(
    _db.aiConversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<void> deleteConversation(String id) => _db.transaction(() async {
    await (_db.delete(
      _db.aiMessages,
    )..where((m) => m.conversationId.equals(id))).go();
    await (_db.delete(_db.aiConversations)..where((c) => c.id.equals(id))).go();
  });

  /// Messages in insertion order (rowid breaks same-second ties).
  Future<List<AiMessage>> messages(String conversationId) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM ai_messages WHERE conversation_id = ? '
          'ORDER BY created_at, rowid',
          variables: [Variable.withString(conversationId)],
          readsFrom: {_db.aiMessages},
        )
        .get();
    return [for (final r in rows) _db.aiMessages.map(r.data)];
  }

  Future<AiMessage> addMessage(
    String conversationId,
    String role,
    List<Map<String, Object?>> blocks, {
    String? provider,
    String? model,
    int? inputTokens,
    int? outputTokens,
  }) async {
    final companion = AiMessagesCompanion.insert(
      id: newId(),
      conversationId: conversationId,
      role: role,
      contentJson: jsonEncode(blocks),
      provider: Value(provider),
      model: Value(model),
      inputTokens: Value(inputTokens),
      outputTokens: Value(outputTokens),
      createdAt: Value(DateTime.now().toUtc()),
    );
    final row = await _db.into(_db.aiMessages).insertReturning(companion);
    await touchConversation(conversationId);
    return row;
  }

  /// Replaces the content of a local-only message (briefing polish).
  Future<void> updateMessageContent(
    String id,
    List<Map<String, Object?>> blocks, {
    String? provider,
    String? model,
  }) => (_db.update(_db.aiMessages)..where((m) => m.id.equals(id))).write(
    AiMessagesCompanion(
      contentJson: Value(jsonEncode(blocks)),
      provider: Value(provider),
      model: Value(model),
    ),
  );

  // -- Memories --------------------------------------------------------------

  Stream<List<AiMemory>> watchMemories() => (_db.select(
    _db.aiMemories,
  )..orderBy([(m) => OrderingTerm.desc(m.updatedAt)])).watch();

  Future<List<AiMemory>> approvedMemories({int limit = 20}) =>
      (_db.select(_db.aiMemories)
            ..where((m) => m.approved.equals(true))
            ..orderBy([(m) => OrderingTerm.desc(m.updatedAt)])
            ..limit(limit))
          .get();

  Future<void> saveMemory({
    String? id,
    required String category,
    required String content,
    bool approved = true,
  }) async {
    final now = DateTime.now().toUtc();
    if (id == null) {
      await _db
          .into(_db.aiMemories)
          .insert(
            AiMemoriesCompanion.insert(
              id: newId(),
              category: category,
              content: content.trim(),
              origin: const Value('user'),
              approved: Value(approved),
            ),
          );
    } else {
      await (_db.update(_db.aiMemories)..where((m) => m.id.equals(id))).write(
        AiMemoriesCompanion(
          category: Value(category),
          content: Value(content.trim()),
          approved: Value(approved),
          updatedAt: Value(now),
        ),
      );
    }
  }

  Future<void> setMemoryApproved(String id, bool approved) =>
      (_db.update(_db.aiMemories)..where((m) => m.id.equals(id))).write(
        AiMemoriesCompanion(
          approved: Value(approved),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<void> deleteMemory(String id) =>
      (_db.delete(_db.aiMemories)..where((m) => m.id.equals(id))).go();

  // -- Audit log & recommendations ------------------------------------------

  Stream<List<AiToolAction>> watchToolActions({
    bool writesOnly = false,
    int limit = 200,
  }) {
    final q = _db.select(_db.aiToolActions)
      ..orderBy([(a) => OrderingTerm.desc(a.createdAt)])
      ..limit(limit);
    if (writesOnly) q.where((a) => a.isWrite.equals(true));
    return q.watch();
  }

  Stream<List<AiRecommendation>> watchRecommendations() => (_db.select(
    _db.aiRecommendations,
  )..orderBy([(r) => OrderingTerm.desc(r.createdAt)])).watch();

  Future<void> respondToRecommendation(
    String id,
    String status, {
    String? editedContent,
  }) =>
      (_db.update(_db.aiRecommendations)..where((r) => r.id.equals(id))).write(
        AiRecommendationsCompanion(
          status: Value(status),
          content: editedContent == null
              ? const Value.absent()
              : Value(editedContent),
          respondedAt: Value(DateTime.now().toUtc()),
        ),
      );
}

final coachRepositoryProvider = Provider<CoachRepository>(
  (ref) => CoachRepository(ref.watch(databaseProvider)),
);

final conversationsProvider = StreamProvider<List<AiConversation>>(
  (ref) => ref.watch(coachRepositoryProvider).watchConversations(),
);

final memoriesProvider = StreamProvider<List<AiMemory>>(
  (ref) => ref.watch(coachRepositoryProvider).watchMemories(),
);

final recommendationsProvider = StreamProvider<List<AiRecommendation>>(
  (ref) => ref.watch(coachRepositoryProvider).watchRecommendations(),
);
