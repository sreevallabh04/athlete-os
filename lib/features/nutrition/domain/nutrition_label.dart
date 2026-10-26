import 'dart:typed_data';

import 'food_models.dart';

/// Which columns a nutrition label prints.
enum LabelBasis {
  per100g('per_100g'),
  perServing('per_serving'),
  both('both'),
  none('none');

  const LabelBasis(this.wire);
  final String wire;

  static LabelBasis fromColumns({
    required bool per100,
    required bool serving,
  }) => per100 && serving
      ? both
      : per100
      ? per100g
      : serving
      ? perServing
      : none;
}

/// One column of a nutrition table (per 100 g/ml, or per serving). Values
/// are exactly what the label says; `null` = not printed / not readable.
class LabelColumn {
  const LabelColumn({
    this.kcal,
    this.protein,
    this.carbs,
    this.fat,
    this.fiber,
    this.sugar,
    this.energyFromKj = false,
  });

  final double? kcal;
  final double? protein;
  final double? carbs;
  final double? fat;
  final double? fiber;
  final double? sugar;

  /// True if [kcal] was converted from a kJ-only label (÷ 4.184).
  final bool energyFromKj;

  static const empty = LabelColumn();

  bool get isEmpty =>
      [kcal, protein, carbs, fat, fiber, sugar].every((v) => v == null);

  /// Energy, protein, carbs and fat all present.
  bool get isComplete =>
      kcal != null && protein != null && carbs != null && fat != null;
}

/// What the AI transcribed from a label photo. Nothing here is an estimate:
/// unreadable values stay `null` and are listed in [unreadableFields].
class NutritionLabelReading {
  const NutritionLabelReading({
    this.productName,
    this.brand,
    this.basis = LabelBasis.none,
    this.per100 = LabelColumn.empty,
    this.serving = LabelColumn.empty,
    this.servingSize,
    this.unit = 'g',
    this.confidence,
    this.unreadableFields = const [],
    this.raw = const {},
  });

  final String? productName;
  final String? brand;
  final LabelBasis basis;
  final LabelColumn per100;
  final LabelColumn serving;

  /// Grams (or ml, see [unit]) in one printed serving.
  final double? servingSize;

  /// 'g' or 'ml' (per 100 ml labels for drinks).
  final String unit;
  final double? confidence;

  /// Field ids the label did not show legibly, e.g. `per_100g.fiber_g`.
  final List<String> unreadableFields;

  /// The tool-call arguments as received (kept in `foods.raw_json`).
  final Map<String, Object?> raw;

  bool get energyFromKj => per100.energyFromKj || serving.energyFromKj;

  /// At least one column has energy + protein + carbs + fat.
  bool get isUsable => per100.isComplete || serving.isComplete;
}

/// Parses `read_nutrition_label` tool arguments defensively. Values that are
/// missing, negative or not numbers become `null` (never guessed); kcal is
/// derived from kJ only when the label prints no kcal (flagged).
NutritionLabelReading parseNutritionLabel(Map<String, dynamic> args) {
  final unreadable = <String>{};
  final rawList = args['unreadable_fields'];
  if (rawList is List) {
    for (final f in rawList.take(20)) {
      final s = f?.toString().trim() ?? '';
      if (s.isNotEmpty) unreadable.add(s.length > 40 ? s.substring(0, 40) : s);
    }
  }

  double? num0(Object? v, double max, String field) {
    if (v == null) return null;
    final d = v is num
        ? v.toDouble()
        : double.tryParse(v.toString().trim().replaceAll(',', '.'));
    if (d == null || !d.isFinite || d < 0 || d > max) {
      unreadable.add(field);
      return null;
    }
    return d;
  }

  LabelColumn column(Object? raw, String prefix) {
    if (raw is! Map) return LabelColumn.empty;
    double? n(String key, double max) => num0(raw[key], max, '$prefix.$key');
    var kcal = n('kcal', 5000);
    var fromKj = false;
    final kj = n('kj', 21000);
    if (kcal == null && kj != null) {
      kcal = _round1(kj / 4.184);
      fromKj = true;
    }
    return LabelColumn(
      kcal: kcal,
      protein: n('protein_g', 1000),
      carbs: n('carbs_g', 1000),
      fat: n('fat_g', 1000),
      fiber: n('fiber_g', 1000),
      sugar: n('sugar_g', 1000),
      energyFromKj: fromKj,
    );
  }

  String? text(Object? v, int max) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty) return null;
    return s.length > max ? s.substring(0, max) : s;
  }

  final per100 = column(args['per_100g'], 'per_100g');
  final serving = column(args['serving'], 'serving');
  final servingRaw = args['serving'];
  final size = servingRaw is Map
      ? num0(servingRaw['size_g'], 5000, 'serving.size_g')
      : null;
  final unit = args['unit'] == 'ml' ? 'ml' : 'g';
  final conf = args['confidence'];
  final confidence = conf is num && conf.isFinite
      ? conf.toDouble().clamp(0, 1).toDouble()
      : null;

  return NutritionLabelReading(
    productName: text(args['product_name'], 120),
    brand: text(args['brand'], 60),
    basis: LabelBasis.fromColumns(
      per100: !per100.isEmpty,
      serving: !serving.isEmpty || (size != null && size > 0),
    ),
    per100: per100,
    serving: serving,
    servingSize: size != null && size > 0 ? size : null,
    unit: unit,
    confidence: confidence,
    unreadableFields: unreadable.toList(),
    raw: Map<String, Object?>.from(args),
  );
}

double _round1(double v) => (v * 10).roundToDouble() / 10;

/// How far the stated kcal is from 4·P + 4·C + 9·F, as a fraction of the
/// stated kcal (0.2 = 20 % off). Null when a value is missing.
double? macroEnergyDeviation({
  double? kcal,
  double? protein,
  double? carbs,
  double? fat,
}) {
  if (kcal == null || protein == null || carbs == null || fat == null) {
    return null;
  }
  final macro = protein * 4 + carbs * 4 + fat * 9;
  if (kcal <= 0) return macro <= 1 ? 0 : 1;
  return (kcal - macro).abs() / kcal;
}

/// Labels round, fibre counts ~2 kcal/g and polyols vary, so only flag
/// clear mismatches.
const macroEnergyTolerance = 0.15;

/// Turns reviewed label values into a [FoodCandidate] (source `custom`) so
/// the shared [FoodCandidate.toBasis] picks the storage basis: per-100 g
/// scaled to the printed serving when both exist, else whichever is
/// complete.
FoodCandidate labelToCandidate({
  required String name,
  String? brand,
  String? barcode,
  required LabelColumn per100,
  required LabelColumn serving,
  double? servingSize,
  String unit = 'g',
  Map<String, Object?> raw = const {},
}) {
  final b = barcode?.trim();
  return FoodCandidate(
    name: name.trim(),
    brand: brand == null || brand.trim().isEmpty ? null : brand.trim(),
    barcode: b == null || b.isEmpty ? null : b,
    source: FoodSources.custom,
    sourceId: b == null || b.isEmpty ? 'label' : 'label:$b',
    kcal100g: per100.kcal,
    protein100g: per100.protein,
    carbs100g: per100.carbs,
    fat100g: per100.fat,
    fiber100g: per100.fiber,
    kcalServing: serving.kcal,
    proteinServing: serving.protein,
    carbsServing: serving.carbs,
    fatServing: serving.fat,
    fiberServing: serving.fiber,
    servingQuantity: servingSize != null && servingSize > 0
        ? servingSize
        : null,
    servingUnit: unit == 'ml' ? 'ml' : 'g',
    energyFromKj: per100.energyFromKj || serving.energyFromKj,
    raw: raw,
  );
}

// ---------------------------------------------------------------------------
// Reader contract (the AI feature provides the implementation)
// ---------------------------------------------------------------------------

sealed class LabelReadResult {
  const LabelReadResult();
}

class LabelReadSuccess extends LabelReadResult {
  const LabelReadSuccess(this.reading, {this.provider});
  final NutritionLabelReading reading;
  final String? provider;
}

class LabelReadUnavailable extends LabelReadResult {
  const LabelReadUnavailable(this.reason);
  final String reason;
}

class LabelReadFailure extends LabelReadResult {
  const LabelReadFailure(this.message);

  /// Already redacted, user-presentable.
  final String message;
}

/// Reads a nutrition-label photo (multimodal AI). Requires
/// `ai_photo_consent`. Transcribes; never estimates.
abstract interface class NutritionLabelReader {
  bool get isConfigured;
  Future<LabelReadResult> read(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  });
}

const labelReaderNotConfiguredMessage =
    'Label reading needs the AI backend, which is not connected. No photo '
    'was sent. You can type the label values instead.';

class UnconfiguredNutritionLabelReader implements NutritionLabelReader {
  const UnconfiguredNutritionLabelReader();
  @override
  bool get isConfigured => false;
  @override
  Future<LabelReadResult> read(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
  }) async => const LabelReadUnavailable(labelReaderNotConfiguredMessage);
}
