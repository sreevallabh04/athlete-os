import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/config/env.dart';
import '../domain/food_models.dart';
import '../domain/rate_limiter.dart';
import 'food_api.dart';

/// Official Open Food Facts API client (no scraping).
///
/// * Barcode: `GET /api/v3/product/{barcode}.json?fields=...`
/// * Search:  `GET /cgi/search.pl?search_terms=...&json=1&page_size=20`
///
/// OFF requires a descriptive User-Agent and asks clients to stay under
/// 15 product reads/min and 10 searches/min per IP; both are enforced
/// client-side here. Searches must be triggered on submit only.
class OpenFoodFactsClient {
  OpenFoodFactsClient({
    required http.Client client,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    String contactEmail = Env.offContactEmail,
    Uri? baseUri,
    Duration timeout = const Duration(seconds: 12),
  }) : _getter = ResilientGetter(
         client: client,
         serviceName: 'Open Food Facts',
         sleep: sleep,
         timeout: timeout,
       ),
       _base = baseUri ?? Uri.parse('https://world.openfoodfacts.org'),
       userAgent = 'AthleteOS/${Env.appVersion} ($contactEmail)',
       productLimiter = RateLimiter(
         maxCalls: 15,
         window: const Duration(minutes: 1),
         now: now,
       ),
       searchLimiter = RateLimiter(
         maxCalls: 10,
         window: const Duration(minutes: 1),
         now: now,
       );

  final ResilientGetter _getter;
  final Uri _base;
  final String userAgent;
  final RateLimiter productLimiter;
  final RateLimiter searchLimiter;

  static const attribution = 'Data from Open Food Facts (ODbL)';

  static const _fields = [
    'code',
    'product_name',
    'product_name_en',
    'generic_name',
    'brands',
    'quantity',
    'serving_size',
    'serving_quantity',
    'serving_quantity_unit',
    'nutrition_data_per',
    'nutriments',
  ];

  Map<String, String> get _headers => {
    'User-Agent': userAgent,
    'Accept': 'application/json',
  };

  /// Looks up a product by barcode. Returns null when OFF does not know it.
  Future<FoodCandidate?> productByBarcode(String barcode) async {
    final code = barcode.trim();
    if (!RegExp(r'^\d{6,14}$').hasMatch(code)) {
      throw FoodApiException(
        FoodApiErrorKind.badResponse,
        'That does not look like a product barcode.',
      );
    }
    final uri = _base.replace(
      path: '/api/v3/product/$code.json',
      queryParameters: {'fields': _fields.join(',')},
    );
    final res = await _getter.get(
      uri,
      headers: _headers,
      limiter: productLimiter,
    );
    final body = _decode(res);
    if (res.statusCode == 404) return null;
    final status = body['status'];
    final result = body['result'];
    final resultId = result is Map ? result['id'] : null;
    if (resultId == 'product_not_found' ||
        (status == 'failure' && body['product'] == null)) {
      return null;
    }
    final product = body['product'];
    if (product is! Map) return null;
    return mapProduct(product.cast<String, Object?>(), fallbackCode: code);
  }

  /// Text search. Call only on explicit submit.
  Future<List<FoodCandidate>> search(String query, {int pageSize = 20}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final uri = _base.replace(
      path: '/cgi/search.pl',
      queryParameters: {
        'search_terms': q,
        'search_simple': '1',
        'action': 'process',
        'json': '1',
        'page_size': '$pageSize',
        'fields': _fields.join(','),
      },
    );
    final res = await _getter.get(
      uri,
      headers: _headers,
      limiter: searchLimiter,
    );
    if (res.statusCode == 404) return const [];
    final body = _decode(res);
    final products = body['products'];
    if (products is! List) return const [];
    final out = <FoodCandidate>[];
    for (final p in products) {
      if (p is! Map) continue;
      final c = mapProduct(p.cast<String, Object?>());
      if (c != null) out.add(c);
    }
    return out;
  }

  Map<String, Object?> _decode(http.Response res) {
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map) return d.cast<String, Object?>();
    } on FormatException {
      // fall through
    }
    if (res.statusCode == 404) return const {};
    throw FoodApiException(
      FoodApiErrorKind.badResponse,
      'Open Food Facts returned data the app could not read.',
    );
  }

  /// Maps an OFF product JSON object. Returns null if it has no usable name.
  /// Missing nutrients stay null (the candidate is then "incomplete").
  static FoodCandidate? mapProduct(
    Map<String, Object?> p, {
    String? fallbackCode,
  }) {
    String? str(Object? v) {
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return null;
    }

    final code = str(p['code']) ?? fallbackCode;
    final name =
        str(p['product_name']) ??
        str(p['product_name_en']) ??
        str(p['generic_name']);
    if (name == null || code == null) return null;
    final brands = str(p['brands']);
    final brand = brands?.split(',').first.trim();

    final nRaw = p['nutriments'];
    final n = nRaw is Map ? nRaw.cast<String, Object?>() : <String, Object?>{};

    var energyFromKj = false;
    double? kcal(String suffix) {
      final direct = parseNum(n['energy-kcal_$suffix']);
      if (direct != null) return direct;
      final kj = parseNum(n['energy-kj_$suffix']);
      if (kj != null) {
        energyFromKj = true;
        return kj / 4.184;
      }
      return null;
    }

    final kcal100 = kcal('100g');
    final kcalServ = kcal('serving');

    final sq = parseNum(p['serving_quantity']);
    final sqUnitRaw = str(p['serving_quantity_unit'])?.toLowerCase();
    final unit = sqUnitRaw == 'ml' ? 'ml' : 'g';

    final raw = <String, Object?>{
      'provider': 'open_food_facts',
      'code': code,
      'product_name': name,
      'brands': ?brands,
      'quantity': ?p['quantity'],
      'serving_size': ?p['serving_size'],
      'serving_quantity': ?p['serving_quantity'],
      'serving_quantity_unit': ?p['serving_quantity_unit'],
      'nutrition_data_per': ?p['nutrition_data_per'],
      'nutriments': {
        for (final k in _nutrientKeys)
          if (n[k] != null) k: n[k],
      },
    };

    return FoodCandidate(
      name: name,
      brand: brand == null || brand.isEmpty ? null : brand,
      barcode: code,
      source: FoodSources.openFoodFacts,
      sourceId: code,
      kcal100g: kcal100,
      protein100g: parseNum(n['proteins_100g']),
      carbs100g: parseNum(n['carbohydrates_100g']),
      fat100g: parseNum(n['fat_100g']),
      fiber100g: parseNum(n['fiber_100g']),
      kcalServing: kcalServ,
      proteinServing: parseNum(n['proteins_serving']),
      carbsServing: parseNum(n['carbohydrates_serving']),
      fatServing: parseNum(n['fat_serving']),
      fiberServing: parseNum(n['fiber_serving']),
      servingQuantity: sq != null && sq > 0 ? sq : null,
      servingUnit: unit,
      servingLabel: str(p['serving_size']),
      energyFromKj: energyFromKj,
      raw: raw,
    );
  }

  static const _nutrientKeys = [
    'energy-kcal_100g',
    'energy-kj_100g',
    'proteins_100g',
    'carbohydrates_100g',
    'fat_100g',
    'fiber_100g',
    'energy-kcal_serving',
    'energy-kj_serving',
    'proteins_serving',
    'carbohydrates_serving',
    'fat_serving',
    'fiber_serving',
  ];
}
