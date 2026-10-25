/// One row of the food-log CSV export.
class FoodLogCsvRow {
  const FoodLogCsvRow({
    required this.localDate,
    required this.loggedAtUtc,
    required this.mealType,
    required this.name,
    this.brand,
    required this.servings,
    this.grams,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.fiber,
    required this.source,
    required this.verification,
    this.note,
  });

  final String localDate;
  final DateTime loggedAtUtc;
  final String mealType;
  final String name;
  final String? brand;
  final double servings;
  final double? grams;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final double? fiber;
  final String source;
  final String verification;
  final String? note;
}

const foodLogCsvHeader = [
  'date',
  'logged_at_utc',
  'meal',
  'food',
  'brand',
  'servings',
  'grams',
  'calories_kcal',
  'protein_g',
  'carbs_g',
  'fat_g',
  'fiber_g',
  'source',
  'verification',
  'note',
];

/// RFC 4180 field escaping. Also neutralises spreadsheet formula injection
/// by prefixing cells that start with = + - @ with a single quote.
String csvField(String? value) {
  if (value == null) return '';
  var v = value;
  if (v.isNotEmpty && '=+-@'.contains(v[0]) && double.tryParse(v) == null) {
    v = "'$v";
  }
  if (v.contains(RegExp(r'[",\r\n]'))) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

String _num(double? v) {
  if (v == null) return '';
  final r = (v * 10).roundToDouble() / 10;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

/// Builds the CSV text (CRLF line endings) for [rows], sorted by date/time.
String buildFoodLogCsv(Iterable<FoodLogCsvRow> rows) {
  final sorted = rows.toList()
    ..sort((a, b) {
      final c = a.localDate.compareTo(b.localDate);
      return c != 0 ? c : a.loggedAtUtc.compareTo(b.loggedAtUtc);
    });
  final b = StringBuffer()..write(foodLogCsvHeader.join(','));
  for (final r in sorted) {
    b
      ..write('\r\n')
      ..write(
        [
          csvField(r.localDate),
          csvField(r.loggedAtUtc.toUtc().toIso8601String()),
          csvField(r.mealType),
          csvField(r.name),
          csvField(r.brand),
          _num(r.servings),
          _num(r.grams),
          _num(r.calories),
          _num(r.protein),
          _num(r.carbs),
          _num(r.fat),
          _num(r.fiber),
          csvField(r.source),
          csvField(r.verification),
          csvField(r.note),
        ].join(','),
      );
  }
  b.write('\r\n');
  return b.toString();
}
