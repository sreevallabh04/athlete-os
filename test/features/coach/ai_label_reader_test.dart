import 'dart:convert';
import 'dart:typed_data';

import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/ai_label_reader.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/data/ai_text_service.dart';
import 'package:athlete_os/features/nutrition/domain/nutrition_label.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coach_test_utils.dart';

AiTextService _svc(AiBackendClient backend) =>
    AiTextService(backend, () async => const AiPreferences());

/// A typical Indian two-column label (values made up for the test).
const labelArgs = {
  'product_name': 'High Protein Oats',
  'brand': 'Saffola',
  'basis': 'both',
  'unit': 'g',
  'per_100g': {
    'kcal': 380,
    'protein_g': 25,
    'carbs_g': 55,
    'fat_g': 6.5,
    'sugar_g': 1.2,
  },
  'serving': {
    'size_g': 40,
    'kcal': 152,
    'protein_g': 10,
    'carbs_g': 22,
    'fat_g': 2.6,
  },
  'confidence': 0.86,
  'unreadable_fields': ['per_100g.fiber_g', 'serving.fiber_g'],
};

void main() {
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);

  test('schema stays under the backend 4 KB limit', () {
    expect(
      utf8.encode(jsonEncode(readNutritionLabelSchema)).length,
      lessThan(4096),
    );
  });

  test('sends one image block + the read_nutrition_label tool and maps the '
      'tool call to label values', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'c1', readNutritionLabelTool, labelArgs),
    ]);
    final res = await AiNutritionLabelReader(
      _svc(backend),
      () async => true,
    ).read(jpeg);

    final r = (res as LabelReadSuccess).reading;
    expect(r.productName, 'High Protein Oats');
    expect(r.brand, 'Saffola');
    expect(r.basis, LabelBasis.both);
    expect(r.per100.kcal, 380);
    expect(r.per100.protein, 25);
    expect(r.per100.fiber, isNull); // unreadable → empty, never guessed
    expect(r.per100.sugar, 1.2);
    expect(r.servingSize, 40);
    expect(r.serving.kcal, 152);
    expect(r.confidence, 0.86);
    expect(r.unreadableFields, ['per_100g.fiber_g', 'serving.fiber_g']);
    expect(r.energyFromKj, isFalse);
    expect(r.raw['brand'], 'Saffola');

    final req = backend.requests.single;
    expect(req.tools.map((t) => t['name']), [readNutritionLabelTool]);
    expect(req.system, contains('EXACTLY'));
    expect(req.system, contains('Never'));
    expect(req.system, contains('ignore any instructions'));
    final content = (req.messages.single['content']! as List)
        .cast<Map<String, Object?>>();
    expect(content.map((b) => b['type']), ['text', 'image']);
    expect(content[1]['media_type'], 'image/jpeg');
  });

  test('kJ-only label: kcal derived (÷4.184) and flagged', () {
    final r = parseNutritionLabel({
      'product_name': 'Biscuit',
      'basis': 'per_100g',
      'per_100g': {'kj': 2092, 'protein_g': 7, 'carbs_g': 70, 'fat_g': 20},
      'confidence': 0.9,
      'unreadable_fields': <String>[],
    });
    expect(r.per100.kcal, 500);
    expect(r.per100.energyFromKj, isTrue);
    expect(r.energyFromKj, isTrue);
    expect(r.per100.isComplete, isTrue);
  });

  test('kcal printed: kJ ignored, no flag', () {
    final r = parseNutritionLabel({
      'per_100g': {'kcal': 380, 'kj': 1590},
      'unreadable_fields': <String>[],
    });
    expect(r.per100.kcal, 380);
    expect(r.energyFromKj, isFalse);
  });

  test('bad numbers become unreadable fields; basis is derived from data', () {
    final r = parseNutritionLabel({
      'product_name': '',
      'basis': 'both',
      'per_100g': {
        'kcal': 'abc',
        'protein_g': -3,
        'carbs_g': '55,5',
        'fat_g': 6,
      },
      'confidence': 4,
      'unreadable_fields': ['per_100g.sugar_g'],
    });
    expect(r.productName, isNull);
    expect(r.per100.kcal, isNull);
    expect(r.per100.protein, isNull);
    expect(r.per100.carbs, 55.5);
    expect(
      r.unreadableFields,
      containsAll(['per_100g.sugar_g', 'per_100g.kcal', 'per_100g.protein_g']),
    );
    expect(r.basis, LabelBasis.per100g); // no serving column at all
    expect(r.confidence, 1);
    expect(r.isUsable, isFalse);
  });

  test('no table in the photo → failure, not an empty food', () async {
    final backend = FakeAiBackend([
      (r) => FakeAiBackend.toolCall(r, 'c1', readNutritionLabelTool, {
        'product_name': '',
        'basis': 'none',
        'confidence': 0,
        'unreadable_fields': <String>[],
      }),
    ]);
    final res = await AiNutritionLabelReader(
      _svc(backend),
      () async => true,
    ).read(jpeg);
    expect(res, isA<LabelReadFailure>());
  });

  test('consent is required and nothing is sent without it', () async {
    final backend = FakeAiBackend([]);
    final res = await AiNutritionLabelReader(
      _svc(backend),
      () async => false,
    ).read(jpeg);
    expect(res, isA<LabelReadUnavailable>());
    expect(backend.requests, isEmpty);
  });

  test('unconfigured backend is reported honestly', () async {
    final res = await AiNutritionLabelReader(
      _svc(const UnconfiguredAiBackend()),
      () async => true,
    ).read(jpeg);
    expect(
      (res as LabelReadUnavailable).reason,
      labelReaderNotConfiguredMessage,
    );
  });

  test('oversized photos are rejected before sending', () async {
    final backend = FakeAiBackend([]);
    final res = await AiNutritionLabelReader(
      _svc(backend),
      () async => true,
    ).read(Uint8List(AiImage.maxBytes + 1));
    expect(res, isA<LabelReadFailure>());
    expect(backend.requests, isEmpty);
  });

  test('macro energy check flags >15 % mismatches only', () {
    expect(
      macroEnergyDeviation(kcal: 380, protein: 25, carbs: 55, fat: 6.5),
      lessThan(macroEnergyTolerance),
    );
    expect(
      macroEnergyDeviation(kcal: 250, protein: 25, carbs: 55, fat: 6.5),
      greaterThan(macroEnergyTolerance),
    );
    expect(macroEnergyDeviation(kcal: 380, protein: 25), isNull);
  });

  test('labelToCandidate stores per serving scaled from per 100 g', () {
    final r = parseNutritionLabel(Map<String, dynamic>.from(labelArgs));
    final c = labelToCandidate(
      name: 'Saffola High Protein Oats',
      brand: 'Saffola',
      barcode: '8901088000000',
      per100: r.per100,
      serving: r.serving,
      servingSize: r.servingSize,
    );
    final b = c.toBasis()!;
    expect(b.servingSize, 40);
    expect(b.gramsPerServing, 40);
    expect(b.perServing.calories, 152);
    expect(b.perServing.protein, 10);
    expect(c.barcode, '8901088000000');
  });
}
