import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/indian_food_db.dart';

/// Bundled asset (per 100 g, user-supplied; see docs/integrations/food-data.md).
const indianFoodCsvAsset = 'assets/data/indian_food_nutrition.csv';

/// Read-only Indian dish database. The CSV is loaded and indexed once,
/// lazily, off the UI isolate; it is never copied into the Foods table
/// (a dish becomes a Food row only when the user logs it).
class IndianFoodDb {
  IndianFoodDb({
    Future<String> Function()? loadCsv,
    Future<IndianFoodIndex> Function(String csv)? build,
  }) : _loadCsv = loadCsv ?? (() => rootBundle.loadString(indianFoodCsvAsset)),
       _build = build ?? ((csv) => compute(buildIndianFoodIndex, csv));

  /// Synchronous parsing (tests, tools).
  factory IndianFoodDb.fromCsv(String csv) => IndianFoodDb(
    loadCsv: () async => csv,
    build: (csv) async => buildIndianFoodIndex(csv),
  );

  final Future<String> Function() _loadCsv;
  final Future<IndianFoodIndex> Function(String csv) _build;
  Future<IndianFoodIndex>? _index;
  IndianFoodIndex? _ready;

  /// The index once loaded (null while loading or after a failure).
  IndianFoodIndex? get readyIndex => _ready;

  /// Loads on first call; later calls share the same future. A failed load
  /// is retried on the next call.
  Future<IndianFoodIndex> index() {
    final existing = _index;
    if (existing != null) return existing;
    final f = () async {
      final idx = await _build(await _loadCsv());
      _ready = idx;
      return idx;
    }();
    _index = f;
    f.catchError((Object _) {
      _index = null;
      return IndianFoodIndex(const []);
    });
    return f;
  }

  /// Starts loading in the background (e.g. when a food screen opens).
  void warmUp() => index().ignore();
}

/// App-lifetime singleton so the CSV is parsed at most once.
final indianFoodDbProvider = Provider<IndianFoodDb>((ref) => IndianFoodDb());
