import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/config/env.dart';
import '../domain/food_models.dart';
import '../domain/rate_limiter.dart';
import 'food_api.dart';

/// USDA FoodData Central search (Foundation + SR Legacy), values per 100 g.
/// Uses the personal `USDA_API_KEY`, or USDA's public `DEMO_KEY` when none is set.
class UsdaClient {
  UsdaClient({
    required http.Client client,
    required this.apiKey,
    bool demoKey = false,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    Uri? baseUri,
  }) : _getter = ResilientGetter(
         client: client,
         serviceName: 'USDA FoodData Central',
         sleep: sleep,
       ),
       _base = baseUri ?? Uri.parse('https://api.nal.usda.gov'),
       // Personal data.gov keys allow 1,000 req/hour; DEMO_KEY ~30/hour per
       // IP. Stay well below either.
       limiter = demoKey
           ? RateLimiter(
               maxCalls: 25,
               window: const Duration(hours: 1),
               now: now,
             )
           : RateLimiter(
               maxCalls: 20,
               window: const Duration(minutes: 1),
               now: now,
             );

  final String apiKey;
  final ResilientGetter _getter;
  final Uri _base;
  final RateLimiter limiter;

  static const attribution = 'USDA FoodData Central (public domain, CC0)';

  // FDC nutrient ids (and legacy nutrient numbers).
  static const energyKcal = 1008; // "208"
  static const energyAtwaterGeneral = 2047; // "957"
  static const energyAtwaterSpecific = 2048; // "958"
  static const protein = 1003; // "203"
  static const carbs = 1005; // "205"
  static const fat = 1004; // "204"
  static const fiber = 1079; // "291"

  Future<List<FoodCandidate>> search(String query, {int pageSize = 20}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    if (apiKey.isEmpty) {
      throw FoodApiException(
        FoodApiErrorKind.notConfigured,
        'USDA search needs a data.gov API key.',
      );
    }
    final uri = _base.replace(
      path: '/fdc/v1/foods/search',
      queryParameters: {
        'api_key': apiKey,
        'query': q,
        'dataType': 'Foundation,SR Legacy',
        'pageSize': '$pageSize',
      },
    );
    final res = await _getter.get(
      uri,
      headers: {
        'Accept': 'application/json',
        'User-Agent': '${Env.userAgent} (${Env.offContactEmail})',
      },
      limiter: limiter,
    );
    if (res.statusCode == 404) return const [];
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw FoodApiException(
        FoodApiErrorKind.badResponse,
        'USDA returned data the app could not read.',
      );
    }
    final foods = body is Map ? body['foods'] : null;
    if (foods is! List) return const [];
    final out = <FoodCandidate>[];
    for (final f in foods) {
      if (f is! Map) continue;
      final c = mapFood(f.cast<String, Object?>());
      if (c != null) out.add(c);
    }
    return out;
  }

  static FoodCandidate? mapFood(Map<String, Object?> f) {
    final id = f['fdcId'];
    final desc = f['description'];
    if (id == null || desc is! String || desc.trim().isEmpty) return null;
    final values = <int, double>{};
    final units = <int, String>{};
    final nutrients = f['foodNutrients'];
    if (nutrients is List) {
      for (final n in nutrients) {
        if (n is! Map) continue;
        var nid = parseNum(n['nutrientId'])?.toInt();
        nid ??= _fromNumber(n['nutrientNumber']);
        final v = parseNum(n['value'] ?? n['amount']);
        if (nid == null || v == null) continue;
        values[nid] = v;
        final u = n['unitName'];
        if (u is String) units[nid] = u.toUpperCase();
      }
    }
    double? energy;
    for (final k in [energyKcal, energyAtwaterGeneral, energyAtwaterSpecific]) {
      if (values[k] != null && (units[k] ?? 'KCAL') == 'KCAL') {
        energy = values[k];
        break;
      }
    }
    final dataType = f['dataType'];
    return FoodCandidate(
      name: _titleCase(desc.trim()),
      brand: f['brandOwner'] is String ? f['brandOwner'] as String : null,
      source: FoodSources.usda,
      sourceId: '$id',
      kcal100g: energy,
      protein100g: values[protein],
      carbs100g: values[carbs],
      fat100g: values[fat],
      fiber100g: values[fiber],
      raw: {
        'provider': 'usda_fdc',
        'fdcId': id,
        'description': desc,
        'dataType': ?dataType,
        'per': '100 g',
        'nutrients': {
          for (final e in values.entries)
            if (const [
              energyKcal,
              energyAtwaterGeneral,
              energyAtwaterSpecific,
              protein,
              carbs,
              fat,
              fiber,
            ].contains(e.key))
              '${e.key}': e.value,
        },
      },
    );
  }

  static int? _fromNumber(Object? number) => switch ('$number') {
    '208' => energyKcal,
    '957' => energyAtwaterGeneral,
    '958' => energyAtwaterSpecific,
    '203' => protein,
    '205' => carbs,
    '204' => fat,
    '291' => fiber,
    _ => null,
  };

  /// "PANEER, RAW" -> "Paneer, raw" (USDA SR descriptions are often caps).
  static String _titleCase(String s) {
    if (s != s.toUpperCase()) return s;
    final lower = s.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }
}
