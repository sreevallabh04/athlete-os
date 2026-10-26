import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/food_log_repository.dart';
import '../domain/food_log_parser.dart';
import '../domain/food_log_review.dart';
import '../domain/food_models.dart';

/// Bulk AI food logging. The AI feature overrides this in
/// `app/overrides.dart`; the default honestly reports "unavailable".
final foodLogParserProvider = Provider<FoodLogParser>(
  (ref) => const UnconfiguredFoodLogParser(),
);

/// Push-to-talk dictation for the composer. Null = no microphone input in
/// this build (the mic button is hidden). Wired to the coach's speech
/// recogniser in `app/overrides.dart`.
abstract interface class FoodDictation {
  /// Starts listening. [onWords] receives partial and final transcripts;
  /// [onLevel] a 0..1 mic level. Returns a user-presentable problem
  /// (permission denied, no recogniser) or null when listening started.
  Future<String?> start({
    required void Function(String words, bool isFinal) onWords,
    void Function(double level)? onLevel,
  });

  /// Stops and delivers the final transcript.
  Future<void> stop();

  /// Stops and discards.
  Future<void> cancel();
}

final foodDictationProvider = Provider<FoodDictation?>((ref) => null);

/// Log drafts for reviewed AI items: `source = ai_estimate`,
/// `verification = estimate`, the item's meal, portion + assumptions as note.
List<LogDraft> logDraftsFor(Iterable<ReviewItem> items) => [
  for (final i in items)
    LogDraft(
      name: i.name,
      mealType: i.mealType,
      nutrients: i.nutrients,
      grams: i.grams,
      source: FoodSources.aiEstimate,
      verification: Verifications.estimate,
      note: i.logNote,
    ),
];

/// Writes every reviewed item for [localDate] in one transaction.
Future<List<String>> logReviewedItems(
  FoodLogRepository repo,
  Iterable<ReviewItem> items, {
  required String localDate,
}) => repo.logAll(logDraftsFor(items), localDate: localDate);
