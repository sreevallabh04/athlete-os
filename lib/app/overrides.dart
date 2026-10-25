import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/contracts/calendar_reader.dart';
import '../features/assistant/application/reply_drafter.dart';
import '../features/coach/data/ai_nutrition_estimators.dart';
import '../features/integrations/data/google_calendar_reader.dart';
import '../features/nutrition/application/providers.dart';
import 'adapters/ai_reply_adapters.dart';

/// Binds shared contracts (declared in `core/`) to their feature
/// implementations. Keeping this wiring in `app/` means `core/` never
/// depends on a feature, and tests can still override each contract.
List<Override> appOverrides() => [
  calendarReaderProvider.overrideWith(
    (ref) => ref.watch(googleCalendarReaderProvider),
  ),
  // Nutrition AI estimates go through the coach's ai-chat backend.
  foodTextEstimatorProvider.overrideWith(
    (ref) => ref.watch(aiFoodTextEstimatorProvider),
  ),
  mealPhotoAnalyzerProvider.overrideWith(
    (ref) => ref.watch(aiMealPhotoAnalyzerProvider),
  ),
  // Messaging assistant drafts/summaries via the same backend. Sending is
  // still decided by the assistant's code-enforced policy engine.
  replyDrafterProvider.overrideWith((ref) => ref.watch(aiReplyDrafterProvider)),
  conversationSummarizerProvider.overrideWith(
    (ref) => ref.watch(aiConversationSummarizerProvider),
  ),
];
