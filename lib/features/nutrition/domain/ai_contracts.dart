import 'dart:typed_data';

import 'nutrients.dart';

/// An AI-estimated food item. ALWAYS shown as ESTIMATE and only saved after
/// explicit user confirmation (verification = `estimate`).
class EstimatedFood {
  const EstimatedFood({
    required this.name,
    required this.nutrients,
    this.quantityDescription,
    this.grams,
    this.confidence,
  });

  final String name;
  final String? quantityDescription;
  final double? grams;
  final Nutrients nutrients;

  /// 0..1 if the provider reports one.
  final double? confidence;
}

sealed class FoodEstimateResult {
  const FoodEstimateResult();
}

class FoodEstimateUnavailable extends FoodEstimateResult {
  const FoodEstimateUnavailable(this.reason);
  final String reason;
}

class FoodEstimateSuccess extends FoodEstimateResult {
  const FoodEstimateSuccess(this.items, {this.provider});
  final List<EstimatedFood> items;
  final String? provider;
}

class FoodEstimateFailure extends FoodEstimateResult {
  const FoodEstimateFailure(this.message);

  /// Already redacted, user-presentable.
  final String message;
}

/// AI fallback for free-text food descriptions the local parser could not
/// match. The AI/coach feature provides the real implementation by
/// overriding `foodTextEstimatorProvider`.
abstract interface class FoodTextEstimator {
  bool get isConfigured;
  Future<FoodEstimateResult> estimate(String text);
}

const aiNotConfiguredMessage =
    'AI estimation unavailable (AI backend not configured)';

class UnconfiguredFoodTextEstimator implements FoodTextEstimator {
  const UnconfiguredFoodTextEstimator();
  @override
  bool get isConfigured => false;
  @override
  Future<FoodEstimateResult> estimate(String text) async =>
      const FoodEstimateUnavailable(aiNotConfiguredMessage);
}

/// Meal-photo analysis (multimodal AI). Requires `ai_photo_consent`.
abstract interface class MealPhotoAnalyzer {
  bool get isConfigured;
  Future<FoodEstimateResult> analyze(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  });
}

const photoNotConfiguredMessage =
    'Meal photo analysis is not configured (AI backend not connected). '
    'No photo was sent anywhere.';

class UnconfiguredMealPhotoAnalyzer implements MealPhotoAnalyzer {
  const UnconfiguredMealPhotoAnalyzer();
  @override
  bool get isConfigured => false;
  @override
  Future<FoodEstimateResult> analyze(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  }) async => const FoodEstimateUnavailable(photoNotConfiguredMessage);
}
