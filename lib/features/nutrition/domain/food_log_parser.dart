/// Bulk free-text food logging ("Tell JARVIS what you ate").
///
/// One call turns a whole pasted day (several meals, bullets, Hinglish dish
/// names, "2 rotis", "1 katori dal", times and headings) into estimated
/// items. Nothing here is saved: the review screen shows every item as an
/// ESTIMATE and only writes after the user taps "Log all".
library;

import 'food_models.dart';
import 'nutrients.dart';

/// Character limit for one paste (keeps the request well under the
/// backend's 16 000-char text limit and the answer under ~4 K tokens).
const foodLogMaxChars = 4000;

/// One item as proposed by the parser (before deterministic sanitising).
class ParsedFoodItem {
  const ParsedFoodItem({
    required this.name,
    required this.nutrients,
    this.quantityDescription,
    this.grams,
    this.mealType,
    this.confidence,
    this.note,
  });

  final String name;

  /// Portion as written or understood, e.g. "2 rotis", "1 katori".
  final String? quantityDescription;

  /// Estimated edible weight (grams or ml) for the whole portion.
  final double? grams;

  /// For the whole portion. `fiber` may be null when unknown.
  final Nutrients nutrients;

  /// Inferred from headings/times/order; null when the text gives no hint.
  final MealType? mealType;

  /// 0..1.
  final double? confidence;

  /// Assumptions the estimator made, e.g. "assumed 1 tsp ghee".
  final String? note;
}

sealed class FoodLogParseResult {
  const FoodLogParseResult();
}

/// The parser cannot run (no AI backend, signed out). Nothing was sent.
class FoodLogParseUnavailable extends FoodLogParseResult {
  const FoodLogParseUnavailable(this.reason);
  final String reason;
}

/// The call failed. [message] is redacted and user-presentable.
class FoodLogParseFailure extends FoodLogParseResult {
  const FoodLogParseFailure(
    this.message, {
    this.retryable = true,
    this.timedOut = false,
  });
  final String message;
  final bool retryable;
  final bool timedOut;
}

class FoodLogParseSuccess extends FoodLogParseResult {
  const FoodLogParseSuccess(
    this.items, {
    this.unparsed = const [],
    this.provider,
    this.model,
  });
  final List<ParsedFoodItem> items;

  /// Fragments of the text the parser could not interpret as food.
  final List<String> unparsed;
  final String? provider;
  final String? model;
}

/// Parses a whole free-form food log. The AI feature provides the real
/// implementation (see `app/overrides.dart`).
abstract interface class FoodLogParser {
  bool get isConfigured;

  /// Whether [parse] can honour `fast: true` (a quicker provider).
  bool get supportsFastMode;

  /// [now] is the user's local time (for "at 8am" / meal inference).
  /// [fast] prefers the quickest provider (e.g. Groq) for this call only.
  Future<FoodLogParseResult> parse(
    String text, {
    required DateTime now,
    bool fast = false,
  });
}

const foodLogAiUnavailableMessage =
    'JARVIS can\'t read meal text right now: the AI backend is not '
    'configured. Nothing was sent.';

/// Default: honestly reports that AI parsing is unavailable.
class UnconfiguredFoodLogParser implements FoodLogParser {
  const UnconfiguredFoodLogParser();

  @override
  bool get isConfigured => false;

  @override
  bool get supportsFastMode => false;

  @override
  Future<FoodLogParseResult> parse(
    String text, {
    required DateTime now,
    bool fast = false,
  }) async => const FoodLogParseUnavailable(foodLogAiUnavailableMessage);
}
