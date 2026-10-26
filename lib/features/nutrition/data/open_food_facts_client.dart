import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/config/env.dart';
import '../domain/food_models.dart';
import '../domain/rate_limiter.dart';
import 'food_api.dart';

/// Official Open Food Facts API client (no scraping).
///
/// * Barcode: `GET /api/v3/product/{barcode}.json?fields=...`
/// * Search, in order (the next one is tried only when the previous fails
///   with 5xx / timeout / unreadable data, e.g. during an OFF outage):
///   1. search-a-licious `GET https://search.openfoodfacts.org/search?q=...`
///   2. legacy `GET /cgi/search.pl?search_terms=...&json=1`
///   3. `GET /api/v2/search?search_terms=...`
///
/// OFF requires a descriptive User-Agent and asks clients to stay under
/// 15 product reads/min and 10 searches/min per IP; both are enforced
/// client-side here (one search slot per user search, fallbacks included).
/// Searches must be triggered on submit only.
class OpenFoodFactsClient {
  OpenFoodFactsClient({
    required http.Client client,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    String contactEmail = Env.offContactEmail,
    Uri? baseUri,
    Uri? searchBaseUri,
    Duration timeout = const Duration(seconds: 12),
  }) : _getter = ResilientGetter(
         client: client,
         serviceName: 'Open Food Facts',
         sleep: sleep,
         timeout: timeout,
       ),
       // Search falls back to another endpoint instead of retrying one.
       _searchGetter = ResilientGetter(
         client: client,
         serviceName: 'Open Food Facts',
         sleep: sleep,
         timeout: timeout,
         maxRetries: 0,
       ),
       _base = baseUri ?? Uri.parse('https://world.openfoodfacts.org'),
       _searchBase =
           searchBaseUri ?? Uri.parse('https://search.openfoodfacts.org'),
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
  final ResilientGetter _searchGetter;
  final Uri _base;
  final Uri _searchBase;
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
  ///
  /// Tries search-a-licious, then `cgi/search.pl`, then `/api/v2/search`.
  /// Throws one compact [FoodApiException] only when all of them fail.
  Future<List<FoodCandidate>> search(String query, {int pageSize = 20}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final wait = searchLimiter.tryAcquire();
    if (wait != null) {
      throw FoodApiException(
        FoodApiErrorKind.rateLimited,
        'Too many Open Food Facts searches. Try again in '
        '${wait.inSeconds < 1 ? 1 : wait.inSeconds} s.',
        retryAfter: wait,
      );
    }
    final failures = <FoodApiException>[];
    for (final endpoint in [_searchALicious, _searchLegacy, _searchV2]) {
      try {
        return await endpoint(q, pageSize);
      } on FoodApiException catch (e) {
        failures.add(e);
      }
    }
    if (failures.every((e) => e.kind == FoodApiErrorKind.offline)) {
      throw failures.last;
    }
    throw FoodApiException(
      FoodApiErrorKind.server,
      'Open Food Facts search is down right now. Your foods, barcode scan '
      'and label scan still work.',
    );
  }

  /// search-a-licious: `{hits: [...]}`; `brands` is a list there.
  Future<List<FoodCandidate>> _searchALicious(String q, int pageSize) async {
    final uri = _searchBase.replace(
      path: '/search',
      queryParameters: {
        'q': q,
        'page_size': '$pageSize',
        'fields': _fields.join(','),
      },
    );
    final body = await _searchJson(uri);
    final hits = body['hits'];
    if (hits is! List) throw _unreadable();
    return _mapAll(hits);
  }

  /// Legacy full-text search: `{products: [...]}`.
  Future<List<FoodCandidate>> _searchLegacy(String q, int pageSize) async {
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
    final body = await _searchJson(uri);
    final products = body['products'];
    if (products is! List) throw _unreadable();
    return _mapAll(products);
  }

  /// API v2 search: `{products: [...]}`.
  Future<List<FoodCandidate>> _searchV2(String q, int pageSize) async {
    final uri = _base.replace(
      path: '/api/v2/search',
      queryParameters: {
        'search_terms': q,
        'page_size': '$pageSize',
        'fields': _fields.join(','),
      },
    );
    final body = await _searchJson(uri);
    final products = body['products'];
    if (products is! List) throw _unreadable();
    return _mapAll(products);
  }

  /// GET + decode for search endpoints. A 404 means "endpoint unavailable"
  /// here (searches never 404 for "no results"), so the next one is tried.
  Future<Map<String, Object?>> _searchJson(Uri uri) async {
    final res = await _searchGetter.get(uri, headers: _headers);
    if (res.statusCode == 404) throw _unreadable();
    return _decode(res);
  }

  FoodApiException _unreadable() => FoodApiException(
    FoodApiErrorKind.badResponse,
    'Open Food Facts returned data the app could not read.',
  );

  static List<FoodCandidate> _mapAll(List<Object?> products) {
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
    // `brands` is "A, B" on the product APIs and ["A", "B"] on
    // search-a-licious.
    final brandsRaw = p['brands'];
    final brands = brandsRaw is List
        ? str(brandsRaw.whereType<String>().join(', '))
        : str(brandsRaw);
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
