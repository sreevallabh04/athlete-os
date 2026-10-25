import 'dart:convert';
import 'dart:io';

import 'package:athlete_os/features/nutrition/data/food_api.dart';
import 'package:athlete_os/features/nutrition/data/open_food_facts_client.dart';
import 'package:athlete_os/features/nutrition/data/usda_client.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonRes(
  Object body, [
  int status = 200,
  Map<String, String>? h,
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...?h},
);

Map<String, Object?> completeProduct() => {
  'code': '8901262150019',
  'status': 'success',
  'result': {'id': 'product_found'},
  'product': {
    'code': '8901262150019',
    'product_name': 'Amul Malai Paneer',
    'brands': 'Amul, GCMMF',
    'serving_size': '50 g',
    'serving_quantity': 50,
    'serving_quantity_unit': 'g',
    'nutriments': {
      'energy-kcal_100g': 288,
      'proteins_100g': '18.9',
      'carbohydrates_100g': 2.3,
      'fat_100g': 22.8,
      'fiber_100g': 0,
    },
  },
};

void main() {
  Future<void> noSleep(Duration _) async {}

  group('OpenFoodFactsClient barcode', () {
    test('maps a complete product and sends the required User-Agent', () async {
      late http.Request captured;
      final client = OpenFoodFactsClient(
        client: MockClient((req) async {
          captured = req;
          return jsonRes(completeProduct());
        }),
        contactEmail: 'me@example.com',
        sleep: noSleep,
      );
      final c = await client.productByBarcode('8901262150019');
      expect(captured.url.path, '/api/v3/product/8901262150019.json');
      expect(captured.url.queryParameters['fields'], contains('nutriments'));
      expect(
        captured.headers['User-Agent'],
        'AthleteOS/1.0.0 (me@example.com)',
      );
      expect(c, isNotNull);
      expect(c!.name, 'Amul Malai Paneer');
      expect(c.brand, 'Amul');
      expect(c.source, FoodSources.openFoodFacts);
      expect(c.kcal100g, 288);
      expect(c.protein100g, 18.9);
      expect(c.isComplete, isTrue);
      expect(c.missingNutrients, isEmpty);
      final basis = c.toBasis()!;
      expect(basis.servingSize, 50);
      expect(basis.gramsPerServing, 50);
      expect(basis.perServing.calories, 144);
      expect(basis.perServing.protein, closeTo(9.45, 1e-9));
      expect((c.raw['nutriments'] as Map)['proteins_100g'], '18.9');
    });

    test('partial nutriments are incomplete and nothing is invented', () async {
      final client = OpenFoodFactsClient(
        client: MockClient(
          (_) async => jsonRes({
            'status': 'success',
            'product': {
              'code': '123456789',
              'product_name': 'Masala Chai Mix',
              'nutriments': {'energy-kcal_100g': 410, 'sugars_100g': 60},
            },
          }),
        ),
        sleep: noSleep,
      );
      final c = (await client.productByBarcode('123456789'))!;
      expect(c.isComplete, isFalse);
      expect(c.missingNutrients, ['protein', 'carbs', 'fat']);
      expect(c.protein100g, isNull);
      expect(c.toBasis(), isNull);
    });

    test('kJ-only energy is converted and flagged', () {
      final c = OpenFoodFactsClient.mapProduct({
        'code': '1234567',
        'product_name': 'Biscuits',
        'nutriments': {
          'energy-kj_100g': 2092,
          'proteins_100g': 7,
          'carbohydrates_100g': 70,
          'fat_100g': 20,
        },
      })!;
      expect(c.kcal100g, closeTo(500, 1e-9));
      expect(c.energyFromKj, isTrue);
    });

    test('per-serving-only data is usable', () {
      final c = OpenFoodFactsClient.mapProduct({
        'code': '1234567',
        'product_name': 'Protein bar',
        'serving_quantity': '40',
        'nutriments': {
          'energy-kcal_serving': 180,
          'proteins_serving': 20,
          'carbohydrates_serving': 15,
          'fat_serving': 5,
        },
      })!;
      expect(c.hasPer100g, isFalse);
      final b = c.toBasis()!;
      expect(b.perServing.calories, 180);
      expect(b.gramsPerServing, 40);
    });

    test('not found (404 + product_not_found) returns null', () async {
      final client = OpenFoodFactsClient(
        client: MockClient(
          (_) async => jsonRes({
            'code': '0000000000',
            'status': 'failure',
            'result': {'id': 'product_not_found'},
          }, 404),
        ),
        sleep: noSleep,
      );
      expect(await client.productByBarcode('0000000000'), isNull);
    });

    test('rejects malformed barcodes without a request', () async {
      var calls = 0;
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return jsonRes({});
        }),
      );
      await expectLater(
        client.productByBarcode('12ab'),
        throwsA(isA<FoodApiException>()),
      );
      expect(calls, 0);
    });

    test('429 retries with backoff, then reports rate limiting', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return jsonRes({}, 429);
        }),
        sleep: (d) async => sleeps.add(d),
      );
      await expectLater(
        client.productByBarcode('8901262150019'),
        throwsA(
          isA<FoodApiException>().having(
            (e) => e.kind,
            'kind',
            FoodApiErrorKind.rateLimited,
          ),
        ),
      );
      expect(calls, 3); // 1 + 2 retries
      expect(sleeps, hasLength(2));
      expect(sleeps[1], greaterThan(sleeps[0]));
    });

    test('5xx then success recovers', () async {
      var calls = 0;
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('oops', 503)
              : jsonRes(completeProduct());
        }),
        sleep: noSleep,
      );
      final c = await client.productByBarcode('8901262150019');
      expect(c, isNotNull);
      expect(calls, 2);
    });

    test('Retry-After header is honoured (capped)', () async {
      final sleeps = <Duration>[];
      var calls = 0;
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? jsonRes({}, 429, {'retry-after': '3'})
              : jsonRes(completeProduct());
        }),
        sleep: (d) async => sleeps.add(d),
      );
      await client.productByBarcode('8901262150019');
      expect(sleeps.single, const Duration(seconds: 3));
    });

    test('offline maps to a friendly offline error', () async {
      final client = OpenFoodFactsClient(
        client: MockClient((_) async => throw const SocketException('no net')),
        sleep: noSleep,
      );
      await expectLater(
        client.productByBarcode('8901262150019'),
        throwsA(
          isA<FoodApiException>().having(
            (e) => e.kind,
            'kind',
            FoodApiErrorKind.offline,
          ),
        ),
      );
    });

    test('client-side limit: at most 15 product reads per minute', () async {
      var now = DateTime(2026, 10, 25, 9);
      var calls = 0;
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return jsonRes(completeProduct());
        }),
        now: () => now,
        sleep: noSleep,
      );
      for (var i = 0; i < 15; i++) {
        await client.productByBarcode('8901262150019');
      }
      await expectLater(
        client.productByBarcode('8901262150019'),
        throwsA(
          isA<FoodApiException>().having(
            (e) => e.kind,
            'kind',
            FoodApiErrorKind.rateLimited,
          ),
        ),
      );
      expect(calls, 15);
      now = now.add(const Duration(minutes: 1));
      await client.productByBarcode('8901262150019');
      expect(calls, 16);
    });
  });

  group('OpenFoodFactsClient search', () {
    test('maps results, skips nameless, keeps incomplete flagged', () async {
      late Uri url;
      final client = OpenFoodFactsClient(
        client: MockClient((req) async {
          url = req.url;
          return jsonRes({
            'count': 3,
            'products': [
              (completeProduct()['product']! as Map),
              {'code': '111111', 'nutriments': {}},
              {
                'code': '222222',
                'product_name': 'Paneer tikka',
                'nutriments': {'energy-kcal_100g': 250},
              },
            ],
          });
        }),
        sleep: noSleep,
      );
      final r = await client.search('paneer');
      expect(url.path, '/cgi/search.pl');
      expect(url.queryParameters['search_terms'], 'paneer');
      expect(url.queryParameters['json'], '1');
      expect(url.queryParameters['page_size'], '20');
      expect(r, hasLength(2));
      expect(r[0].isComplete, isTrue);
      expect(r[1].isComplete, isFalse);
    });

    test('limits searches to 10 per minute', () async {
      final now = DateTime(2026, 10, 25, 9);
      final client = OpenFoodFactsClient(
        client: MockClient((_) async => jsonRes({'products': []})),
        now: () => now,
        sleep: noSleep,
      );
      for (var i = 0; i < 10; i++) {
        await client.search('dal');
      }
      await expectLater(client.search('dal'), throwsA(isA<FoodApiException>()));
    });

    test('short queries do not hit the network', () async {
      var calls = 0;
      final client = OpenFoodFactsClient(
        client: MockClient((_) async {
          calls++;
          return jsonRes({});
        }),
      );
      expect(await client.search(' a '), isEmpty);
      expect(calls, 0);
    });
  });

  group('UsdaClient', () {
    Map<String, Object?> usdaBody() => {
      'foods': [
        {
          'fdcId': 173430,
          'description': 'CHEESE,PANEER',
          'dataType': 'SR Legacy',
          'foodNutrients': [
            {'nutrientId': 1008, 'unitName': 'KCAL', 'value': 321},
            {'nutrientId': 1003, 'unitName': 'G', 'value': 25},
            {'nutrientId': 1005, 'unitName': 'G', 'value': 3.57},
            {'nutrientId': 1004, 'unitName': 'G', 'value': 25},
            {'nutrientId': 1079, 'unitName': 'G', 'value': 0},
          ],
        },
        {
          'fdcId': 2003590,
          'description': 'Rice, white, cooked',
          'dataType': 'Foundation',
          'foodNutrients': [
            {'nutrientNumber': '957', 'unitName': 'KCAL', 'amount': 130},
            {'nutrientNumber': '203', 'unitName': 'G', 'amount': 2.7},
            {'nutrientNumber': '205', 'unitName': 'G', 'amount': 28.6},
            {'nutrientNumber': '204', 'unitName': 'G', 'amount': 0.3},
          ],
        },
        {
          'fdcId': 9,
          'description': 'Lentils, partial',
          'foodNutrients': [
            {'nutrientId': 1062, 'unitName': 'kJ', 'value': 400},
            {'nutrientId': 1003, 'unitName': 'G', 'value': 9},
          ],
        },
      ],
    };

    test('maps per-100 g nutrients incl. Atwater energy fallback', () async {
      late Uri url;
      final client = UsdaClient(
        client: MockClient((req) async {
          url = req.url;
          return jsonRes(usdaBody());
        }),
        apiKey: 'test-key-123',
        sleep: noSleep,
      );
      final r = await client.search('paneer');
      expect(url.path, '/fdc/v1/foods/search');
      expect(url.queryParameters['api_key'], 'test-key-123');
      expect(url.queryParameters['dataType'], 'Foundation,SR Legacy');
      expect(r, hasLength(3));
      expect(r[0].name, 'Cheese,paneer');
      expect(r[0].source, FoodSources.usda);
      expect(r[0].kcal100g, 321);
      expect(r[0].protein100g, 25);
      expect(r[0].isComplete, isTrue);
      expect(r[0].toBasis()!.gramsPerServing, 100);
      expect(r[1].kcal100g, 130);
      expect(r[1].carbs100g, 28.6);
      expect(r[2].isComplete, isFalse);
      expect(r[2].kcal100g, isNull);
    });

    test('errors never leak the API key', () async {
      final client = UsdaClient(
        client: MockClient((_) async => http.Response('bad', 403)),
        apiKey: 'secret-key-abcdef',
        sleep: noSleep,
      );
      try {
        await client.search('rice');
        fail('should throw');
      } on FoodApiException catch (e) {
        expect(e.kind, FoodApiErrorKind.notConfigured);
        expect(e.message, isNot(contains('secret-key-abcdef')));
      }
    });

    test('empty key is reported as not configured', () async {
      final client = UsdaClient(
        client: MockClient((_) async => jsonRes({})),
        apiKey: '',
      );
      await expectLater(
        client.search('rice'),
        throwsA(
          isA<FoodApiException>().having(
            (e) => e.kind,
            'kind',
            FoodApiErrorKind.notConfigured,
          ),
        ),
      );
    });
  });

  group('RateLimiter', () {
    test('sliding window', () {
      var now = DateTime(2026);
      final l = RateLimiter(
        maxCalls: 2,
        window: const Duration(seconds: 60),
        now: () => now,
      );
      expect(l.tryAcquire(), isNull);
      now = now.add(const Duration(seconds: 10));
      expect(l.tryAcquire(), isNull);
      expect(l.tryAcquire(), const Duration(seconds: 50));
      expect(l.remaining, 0);
      now = now.add(const Duration(seconds: 50));
      expect(l.tryAcquire(), isNull);
    });
  });

  test('parseNum handles numbers, strings and junk', () {
    expect(parseNum(3), 3.0);
    expect(parseNum('4,5'), 4.5);
    expect(parseNum('abc'), isNull);
    expect(parseNum(null), isNull);
    expect(parseNum(double.nan), isNull);
  });
}
