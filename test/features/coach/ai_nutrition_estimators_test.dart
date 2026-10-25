import 'dart:typed_data';

import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_nutrition_estimators.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/data/ai_text_service.dart';
import 'package:athlete_os/features/nutrition/domain/ai_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coach_test_utils.dart';

AiTextService _svc(AiBackendClient backend) =>
    AiTextService(backend, () async => const AiPreferences());

const _items = {
  'items': [
    {
      'name': 'Chapati',
      'quantity': '2 medium',
      'grams': 80,
      'kcal': 240,
      'protein_g': 7.6,
      'carbs_g': 40.2,
      'fat_g': 6.04,
      'confidence': 0.7,
    },
    {
      'name': 'Dal tadka',
      'grams': 200,
      'kcal': 260,
      'protein_g': 12,
      'carbs_g': 30,
      'fat_g': 9,
      'confidence': 1.4, // clamped
    },
    {'name': '', 'kcal': 10}, // dropped: no name
    {'name': 'Mystery', 'kcal': 'n/a'}, // dropped: no kcal
  ],
};

void main() {
  test('schema stays under the backend 4 KB limit', () {
    expect(
      Uri.encodeFull(proposeFoodItemsSchema.toString()).length,
      lessThan(4096),
    );
  });

  test(
    'text estimator sends only propose_food_items and parses items',
    () async {
      final backend = FakeAiBackend([
        (r) => FakeAiBackend.toolCall(r, 'c1', proposeFoodItemsTool, _items),
      ]);
      final res = await AiFoodTextEstimator(_svc(backend))
          .estimate('2 chapati and a bowl of dal');

      expect(res, isA<FoodEstimateSuccess>());
      final items = (res as FoodEstimateSuccess).items;
      expect(items.map((i) => i.name), ['Chapati', 'Dal tadka']);
      expect(items[0].quantityDescription, '2 medium');
      expect(items[0].grams, 80);
      expect(items[0].nutrients.calories, 240);
      expect(items[0].nutrients.fat, 6.0);
      expect(items[1].confidence, 1.0);

      final req = backend.requests.single;
      expect(req.tools.map((t) => t['name']), [proposeFoodItemsTool]);
      expect(req.system, contains('ESTIMATE'));
      final text =
          ((req.messages.single['content']! as List).first as Map)['text']
              as String;
      expect(text, contains('2 chapati and a bowl of dal'));
    },
  );

  test(
    'text estimator: prose answer -> failure, backend error -> failure',
    () async {
      final prose = await AiFoodTextEstimator(
        _svc(FakeAiBackend([(r) => FakeAiBackend.text(r, 'About 500 kcal')])),
      ).estimate('lunch');
      expect(prose, isA<FoodEstimateFailure>());

      final err = await AiFoodTextEstimator(
        _svc(
          FakeAiBackend([
            (_) => throw const AiBackendException('timeout', 'Too slow.'),
          ]),
        ),
      ).estimate('lunch');
      expect((err as FoodEstimateFailure).message, 'Too slow.');
    },
  );

  test('unconfigured / signed-out backends are reported, not faked', () async {
    final un = await AiFoodTextEstimator(_svc(const UnconfiguredAiBackend()))
        .estimate('rice');
    expect(un, isA<FoodEstimateUnavailable>());
    final out = await AiFoodTextEstimator(
      _svc(const UnconfiguredAiBackend(signedOut: true)),
    ).estimate('rice');
    expect((out as FoodEstimateUnavailable).reason, contains('sign-in'));
  });

  test(
    'photo analyzer requires consent and sends nothing without it',
    () async {
      final backend = FakeAiBackend([]);
      final res = await AiMealPhotoAnalyzer(
        _svc(backend),
        () async => false,
      ).analyze(Uint8List.fromList([1, 2, 3]));
      expect(res, isA<FoodEstimateUnavailable>());
      expect(backend.requests, isEmpty);
    },
  );

  test('photo analyzer sends one image block and parses items', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'c1', proposeFoodItemsTool, _items),
    ]);
    final res = await AiMealPhotoAnalyzer(
      _svc(backend),
      () async => true,
    ).analyze(Uint8List.fromList([0xFF, 0xD8, 1]), mimeType: 'image/jpg');
    expect((res as FoodEstimateSuccess).items, hasLength(2));
    final content =
        (backend.requests.single.messages.single['content']! as List)
            .cast<Map<String, Object?>>();
    expect(content.map((b) => b['type']), ['text', 'image']);
    expect(content[1]['media_type'], 'image/jpeg');
  });

  test('photo analyzer rejects oversized photos before sending', () async {
    final backend = FakeAiBackend([]);
    final res = await AiMealPhotoAnalyzer(
      _svc(backend),
      () async => true,
    ).analyze(Uint8List(AiImage.maxBytes + 1));
    expect(res, isA<FoodEstimateFailure>());
    expect(backend.requests, isEmpty);
  });
}
