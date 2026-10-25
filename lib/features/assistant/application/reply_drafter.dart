import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/assistant_settings.dart';

/// One captured message given to the drafter.
class DraftMessage {
  const DraftMessage({required this.text, required this.at, this.sender});
  final String? sender;
  final String text;
  final DateTime at;
}

/// Everything a drafter may see: ONLY the captured notification text(s) of
/// this conversation within retention, plus the tone profile. Nothing else
/// from the app (no health data, no other chats).
class DraftRequest {
  const DraftRequest({
    required this.appLabel,
    required this.conversationTitle,
    required this.isGroup,
    required this.messages,
    required this.tone,
    this.contactTone,
    this.maxLength = 160,
  });

  final String appLabel;
  final String? conversationTitle;
  final bool isGroup;
  final List<DraftMessage> messages;
  final ToneProfile tone;
  final ContactTone? contactTone;
  final int maxLength;
}

class DraftResult {
  const DraftResult({
    required this.text,
    required this.category,
    required this.confidence,
    this.needsHumanReason,
  });

  /// No draft could be produced; [needsHumanReason] says why.
  const DraftResult.unavailable(String reason)
    : text = null,
      category = null,
      confidence = 0,
      needsHumanReason = reason;

  final String? text;

  /// One of [ReplyCategory] values.
  final String? category;

  /// 0..1
  final double confidence;
  final String? needsHumanReason;

  bool get available => text != null && text!.trim().isNotEmpty;
}

/// Produces reply drafts. Implemented by the AI backend (coach client) and
/// injected by overriding [replyDrafterProvider].
abstract interface class ReplyDrafter {
  bool get isConfigured;
  Future<DraftResult> draft(DraftRequest request);
}

const aiUnavailableMessage =
    'AI drafting unavailable — AI backend not configured';

/// Default drafter until the AI backend is wired. Never fakes output.
class UnconfiguredReplyDrafter implements ReplyDrafter {
  const UnconfiguredReplyDrafter();

  @override
  bool get isConfigured => false;

  @override
  Future<DraftResult> draft(DraftRequest request) async =>
      const DraftResult.unavailable(aiUnavailableMessage);
}

final replyDrafterProvider = Provider<ReplyDrafter>(
  (ref) => const UnconfiguredReplyDrafter(),
);

/// AI conversation summary (consent-gated like drafting).
abstract interface class ConversationSummarizer {
  bool get isConfigured;

  /// Returns a short summary, or null when unavailable.
  Future<String?> summarize(DraftRequest request);
}

class UnconfiguredConversationSummarizer implements ConversationSummarizer {
  const UnconfiguredConversationSummarizer();
  @override
  bool get isConfigured => false;
  @override
  Future<String?> summarize(DraftRequest request) async => null;
}

final conversationSummarizerProvider = Provider<ConversationSummarizer>(
  (ref) => const UnconfiguredConversationSummarizer(),
);
