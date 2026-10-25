import 'nutrients.dart';

/// Deterministic, offline parser for phrases like
/// "150 g paneer, 200 g rice and one banana".
///
/// It only *parses*; matching to foods is done by [matchParsedFoods] against
/// the user's local foods/recents. Nothing is estimated here.
enum ParsedUnit { gram, millilitre, cup, piece, serving }

class ParsedFoodItem {
  const ParsedFoodItem({
    required this.raw,
    required this.quantity,
    required this.unit,
    required this.name,
    this.explicitQuantity = true,
  });

  /// Original segment text.
  final String raw;

  /// Quantity in [unit] (kg/l are converted to g/ml).
  final double quantity;
  final ParsedUnit unit;

  /// Food name with quantity/unit words removed.
  final String name;

  /// False when no number/word quantity was found (defaults to 1 serving).
  final bool explicitQuantity;

  @override
  String toString() => 'ParsedFoodItem($quantity ${unit.name} "$name")';
}

const _numberWords = <String, double>{
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'half': 0.5,
  'quarter': 0.25,
  'dozen': 12,
  'couple': 2,
};

const _unicodeFractions = <String, double>{
  '½': 0.5,
  '¼': 0.25,
  '¾': 0.75,
  '⅓': 1 / 3,
  '⅔': 2 / 3,
};

/// Unit tokens → (unit, multiplier to the canonical unit).
const _units = <String, (ParsedUnit, double)>{
  'g': (ParsedUnit.gram, 1),
  'gm': (ParsedUnit.gram, 1),
  'gms': (ParsedUnit.gram, 1),
  'gr': (ParsedUnit.gram, 1),
  'gram': (ParsedUnit.gram, 1),
  'grams': (ParsedUnit.gram, 1),
  'gramme': (ParsedUnit.gram, 1),
  'grammes': (ParsedUnit.gram, 1),
  'kg': (ParsedUnit.gram, 1000),
  'kgs': (ParsedUnit.gram, 1000),
  'kilo': (ParsedUnit.gram, 1000),
  'kilos': (ParsedUnit.gram, 1000),
  'kilogram': (ParsedUnit.gram, 1000),
  'kilograms': (ParsedUnit.gram, 1000),
  'ml': (ParsedUnit.millilitre, 1),
  'mls': (ParsedUnit.millilitre, 1),
  'millilitre': (ParsedUnit.millilitre, 1),
  'millilitres': (ParsedUnit.millilitre, 1),
  'milliliter': (ParsedUnit.millilitre, 1),
  'milliliters': (ParsedUnit.millilitre, 1),
  'l': (ParsedUnit.millilitre, 1000),
  'litre': (ParsedUnit.millilitre, 1000),
  'litres': (ParsedUnit.millilitre, 1000),
  'liter': (ParsedUnit.millilitre, 1000),
  'liters': (ParsedUnit.millilitre, 1000),
  'cup': (ParsedUnit.cup, 1),
  'cups': (ParsedUnit.cup, 1),
  'piece': (ParsedUnit.piece, 1),
  'pieces': (ParsedUnit.piece, 1),
  'pc': (ParsedUnit.piece, 1),
  'pcs': (ParsedUnit.piece, 1),
  'serving': (ParsedUnit.serving, 1),
  'servings': (ParsedUnit.serving, 1),
  'portion': (ParsedUnit.serving, 1),
  'portions': (ParsedUnit.serving, 1),
};

final _splitter = RegExp(
  r'\s*(?:,|;|\n|\+|&|\band\b|\bwith\b|\bplus\b)\s*',
  caseSensitive: false,
);

// "150g", "1.5kg", "200 ml" glued forms.
final _glued = RegExp(r'^(\d+(?:[.,]\d+)?)([a-zA-Z]+)$');
final _number = RegExp(r'^\d+(?:[.,]\d+)?$');
final _fraction = RegExp(r'^(\d+)/(\d+)$');

List<ParsedFoodItem> parseFoodText(String input) {
  final out = <ParsedFoodItem>[];
  for (final seg in input.split(_splitter)) {
    final item = _parseSegment(seg.trim());
    if (item != null) out.add(item);
  }
  return out;
}

ParsedFoodItem? _parseSegment(String seg) {
  if (seg.isEmpty) return null;
  final tokens = seg
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;

  double? qty;
  ParsedUnit? unit;
  var multiplier = 1.0;
  var i = 0;

  // Quantity: number, fraction, unicode fraction, "1 1/2", or number word.
  String lower(int k) => tokens[k].toLowerCase();
  if (i < tokens.length) {
    final t = lower(i);
    final glued = _glued.firstMatch(t);
    if (glued != null && _units.containsKey(glued.group(2))) {
      qty = double.parse(glued.group(1)!.replaceAll(',', '.'));
      final u = _units[glued.group(2)]!;
      unit = u.$1;
      multiplier = u.$2;
      i++;
    } else if (_number.hasMatch(t)) {
      qty = double.parse(t.replaceAll(',', '.'));
      i++;
      // Mixed number: "1 1/2".
      if (i < tokens.length) {
        final f = _fraction.firstMatch(lower(i));
        if (f != null && int.parse(f.group(2)!) != 0) {
          qty += int.parse(f.group(1)!) / int.parse(f.group(2)!);
          i++;
        }
      }
    } else if (_fraction.hasMatch(t)) {
      final f = _fraction.firstMatch(t)!;
      final den = int.parse(f.group(2)!);
      if (den != 0) {
        qty = int.parse(f.group(1)!) / den;
        i++;
      }
    } else if (_unicodeFractions.containsKey(t)) {
      qty = _unicodeFractions[t];
      i++;
    } else if (_numberWords.containsKey(t)) {
      qty = _numberWords[t];
      i++;
      // "half a banana", "a couple of eggs"
      if (i < tokens.length && (lower(i) == 'a' || lower(i) == 'an')) i++;
      if (t == 'couple' && i < tokens.length && lower(i) == 'of') i++;
    }
  }

  // Unit (if not glued).
  if (unit == null && i < tokens.length) {
    final u = _units[lower(i)];
    // Do not treat a lone "l"/"g" as a unit without a quantity.
    if (u != null && qty != null) {
      unit = u.$1;
      multiplier = u.$2;
      i++;
    }
  }
  if (i < tokens.length && lower(i) == 'of') i++;

  final name = tokens.sublist(i).join(' ').trim();
  if (name.isEmpty) return null;

  final explicit = qty != null;
  return ParsedFoodItem(
    raw: seg,
    quantity: (qty ?? 1) * multiplier,
    unit: unit ?? (explicit ? ParsedUnit.piece : ParsedUnit.serving),
    name: name,
    explicitQuantity: explicit,
  );
}

/// A local food that parsed items can be matched against.
class FoodRef {
  const FoodRef({
    required this.id,
    required this.name,
    required this.basis,
    this.brand,
  });
  final String id;
  final String name;
  final String? brand;
  final ServingBasis basis;
}

enum MatchStatus {
  /// Food found and amount converted.
  matched,

  /// Food found but the unit cannot be converted (e.g. "cup" for a food
  /// defined per 100 g). The user must pick an amount.
  needsAmount,

  /// No local food matched; needs a database lookup.
  needsLookup,
}

class FoodMatch {
  const FoodMatch({
    required this.item,
    required this.status,
    this.food,
    this.amount,
    this.resolved,
  });
  final ParsedFoodItem item;
  final MatchStatus status;
  final FoodRef? food;
  final Amount? amount;
  final ResolvedAmount? resolved;
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Strips a simple plural "s"/"es" so "bananas" matches "banana".
String _singular(String w) {
  if (w.length > 3 && w.endsWith('ies')) {
    return '${w.substring(0, w.length - 3)}y';
  }
  if (w.length > 3 && w.endsWith('oes')) return w.substring(0, w.length - 2);
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) {
    return w.substring(0, w.length - 1);
  }
  return w;
}

Set<String> _words(String s) =>
    _norm(s).split(' ').where((w) => w.isNotEmpty).map(_singular).toSet();

/// Score how well [query] matches [candidate]; 0 = no match.
/// 100 exact; 80 all query words present in the name; 60 all name words
/// present in the query; otherwise Jaccard overlap * 50 (>= 25 to count).
int matchScore(String query, String candidate) {
  final q = _words(query);
  final c = _words(candidate);
  if (q.isEmpty || c.isEmpty) return 0;
  if (q.length == c.length && q.containsAll(c)) return 100;
  if (c.containsAll(q)) return 80 - (c.length - q.length).clamp(0, 10);
  if (q.containsAll(c)) return 60;
  final inter = q.intersection(c).length;
  final union = q.union(c).length;
  final j = (inter / union * 50).round();
  return j >= 25 ? j : 0;
}

/// Matches each parsed item to the best local food and converts the amount.
/// [foods] should be ordered by preference (e.g. recents first); earlier
/// foods win ties.
List<FoodMatch> matchParsedFoods(
  List<ParsedFoodItem> items,
  List<FoodRef> foods,
) {
  return [for (final item in items) _matchOne(item, foods)];
}

FoodMatch _matchOne(ParsedFoodItem item, List<FoodRef> foods) {
  FoodRef? best;
  var bestScore = 0;
  for (final f in foods) {
    final s = matchScore(item.name, f.name);
    if (s > bestScore) {
      best = f;
      bestScore = s;
    }
  }
  if (best == null) {
    return FoodMatch(item: item, status: MatchStatus.needsLookup);
  }
  final amount = _convert(item, best.basis);
  if (amount == null) {
    return FoodMatch(item: item, status: MatchStatus.needsAmount, food: best);
  }
  return FoodMatch(
    item: item,
    status: MatchStatus.matched,
    food: best,
    amount: amount,
    resolved: resolveAmount(best.basis, amount),
  );
}

Amount? _convert(ParsedFoodItem item, ServingBasis basis) {
  final unit = basis.servingUnit.toLowerCase();
  switch (item.unit) {
    case ParsedUnit.gram:
      if (basis.supportsGrams && basis.baseUnit == 'g') {
        return Amount.grams(item.quantity);
      }
      return null;
    case ParsedUnit.millilitre:
      if (basis.supportsGrams && basis.baseUnit == 'ml') {
        return Amount.grams(item.quantity);
      }
      return null;
    case ParsedUnit.cup:
      if (unit == 'cup' || unit == 'cups') {
        return Amount.servings(item.quantity / basis.servingSize);
      }
      return null;
    case ParsedUnit.piece:
      if (unit == 'piece' || unit == 'pieces' || unit == 'pc') {
        return Amount.servings(item.quantity / basis.servingSize);
      }
      if (unit == 'serving' || unit == 'slice') {
        return Amount.servings(item.quantity);
      }
      // "one banana" for a per-100 g food cannot be converted honestly.
      return null;
    case ParsedUnit.serving:
      return Amount.servings(item.quantity);
  }
}
