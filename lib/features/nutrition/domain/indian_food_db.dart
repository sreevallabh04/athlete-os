/// Offline Indian dish database (user-supplied CSV, values per 100 g):
/// CSV parsing, alias extraction, a small in-memory search index and a
/// conservative name matcher used to ground AI food-log estimates. Pure Dart
/// (runs in an isolate via `compute`), unit tested.
library;

import 'food_models.dart';
import 'nutrients.dart';

/// One dish row. Values are per 100 g; micronutrients may be missing.
class IndianDish {
  const IndianDish({
    required this.id,
    required this.name,
    required this.kcal,
    required this.carbs,
    required this.protein,
    required this.fat,
    this.sugar,
    this.fiber,
    this.sodiumMg,
    this.calciumMg,
    this.ironMg,
    this.vitaminCMg,
    this.folateUg,
  });

  /// 1-based data row number in the CSV (stable id for saved foods).
  final int id;

  /// As written in the CSV, e.g. "Hot tea (Garam Chai)".
  final String name;
  final double kcal;
  final double carbs;
  final double protein;
  final double fat;
  final double? sugar;
  final double? fiber;
  final double? sodiumMg;
  final double? calciumMg;
  final double? ironMg;
  final double? vitaminCMg;
  final double? folateUg;

  Nutrients get per100g => Nutrients(
    calories: kcal,
    protein: protein,
    carbs: carbs,
    fat: fat,
    fiber: fiber,
  );

  /// Nutrients for [grams] of the dish.
  Nutrients forGrams(double grams) => per100gToAmount(per100g, grams);

  /// Values kept in `foods.raw_json` / log notes (incl. sugar, sodium...).
  Map<String, Object?> toRawJson() => {
    'provider': 'indian_food_db',
    'row': id,
    'dish_name': name,
    'per_100g': {
      'kcal': kcal,
      'carbs_g': carbs,
      'protein_g': protein,
      'fat_g': fat,
      'free_sugar_g': ?sugar,
      'fibre_g': ?fiber,
      'sodium_mg': ?sodiumMg,
      'calcium_mg': ?calciumMg,
      'iron_mg': ?ironMg,
      'vitamin_c_mg': ?vitaminCMg,
      'folate_ug': ?folateUg,
    },
  };

  /// A remote-style candidate (per 100 g) for the shared amount/save flow.
  FoodCandidate toCandidate() => FoodCandidate(
    name: name,
    source: FoodSources.indianFoodDb,
    sourceId: 'row$id',
    kcal100g: kcal,
    protein100g: protein,
    carbs100g: carbs,
    fat100g: fat,
    fiber100g: fiber,
    raw: toRawJson(),
  );
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

/// RFC 4180 CSV: quoted fields may contain commas, quotes ("") and newlines.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  // Skip a UTF-8 BOM.
  if (text.startsWith('﻿')) i = 1;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (!(row.length == 1 && row.first.trim().isEmpty)) rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        field.write(ch);
      }
      i++;
      continue;
    }
    switch (ch) {
      case '"':
        quoted = true;
      case ',':
        endField();
      case '\r':
        break;
      case '\n':
        endRow();
      default:
        field.write(ch);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

double? _num(List<String> r, int i) {
  if (i >= r.length) return null;
  final t = r[i].trim();
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v != null && v.isFinite && v >= 0 ? v : null;
}

/// Parses the dish CSV (header first). Rows without a name or without
/// energy/carbs/protein/fat are skipped; empty micronutrient cells → null.
List<IndianDish> parseIndianFoodCsv(String text) {
  final rows = parseCsv(text);
  final out = <IndianDish>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final name = row.isEmpty ? '' : row[0].trim();
    final kcal = _num(row, 1);
    final carbs = _num(row, 2);
    final protein = _num(row, 3);
    final fat = _num(row, 4);
    if (name.isEmpty ||
        kcal == null ||
        carbs == null ||
        protein == null ||
        fat == null) {
      continue;
    }
    out.add(
      IndianDish(
        id: r,
        name: name,
        kcal: kcal,
        carbs: carbs,
        protein: protein,
        fat: fat,
        sugar: _num(row, 5),
        fiber: _num(row, 6),
        sodiumMg: _num(row, 7),
        calciumMg: _num(row, 8),
        ironMg: _num(row, 9),
        vitaminCMg: _num(row, 10),
        folateUg: _num(row, 11),
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Text normalisation & aliases
// ---------------------------------------------------------------------------

const _diacritics = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a', //
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ñ': 'n', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ṣ': 's', 'ṭ': 't',
  'ḍ': 'd', 'ṇ': 'n', 'ṃ': 'm', 'ṅ': 'n', 'ś': 's', 'ý': 'y', 'µ': 'u',
};

/// Lowercase, diacritics folded, punctuation → spaces, single-spaced.
String normalizeFoodText(String s) {
  final b = StringBuffer();
  for (final rune in s.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final folded = _diacritics[ch] ?? ch;
    final c = folded.codeUnitAt(0);
    final alnum = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
    b.write(folded.length == 1 && alnum ? folded : (ch == '&' ? ' and ' : ' '));
  }
  return b.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// "Dal parantha/paratha" → [Dal parantha, Dal paratha];
/// "Suji/Rava upma" → [Suji upma, Rava upma]; "Chapati/Roti" → both.
List<String> expandSlashVariants(String s) {
  final parts = [
    for (final p in s.split('/'))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (parts.length <= 1) return parts;
  bool multi(String p) => p.contains(' ');
  final out = <String>[];
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (multi(p)) {
      out.add(p);
      continue;
    }
    String? base;
    var after = true;
    for (var j = i - 1; j >= 0 && base == null; j--) {
      if (multi(parts[j])) base = parts[j];
    }
    if (base == null) {
      after = false;
      for (var j = i + 1; j < parts.length && base == null; j++) {
        if (multi(parts[j])) base = parts[j];
      }
    }
    if (base == null) {
      out.add(p);
      continue;
    }
    final words = base.split(' ');
    if (after) {
      words[words.length - 1] = p;
    } else {
      words[0] = p;
    }
    out.add(words.join(' '));
  }
  return out;
}

/// Display names a dish is known by: the English name (+ slash variants)
/// and the bracketed alias list (comma / slash separated). With several
/// bracket groups, the last one is the alias list and earlier ones are
/// descriptors ("Paneer pea sandwich (toasted) (Paneer matar ka sandwich)").
List<String> dishAliases(String name) {
  final groups = RegExp(r'\(([^)]*)\)').allMatches(name).toList();
  var english = name.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  String? aliasGroup;
  if (groups.isNotEmpty) {
    aliasGroup = groups.last.group(1);
    for (final g in groups.take(groups.length - 1)) {
      english = '$english ${g.group(1)}';
    }
  }
  english = english.replaceAll(RegExp(r'\s+'), ' ').trim();
  final out = <String>[...expandSlashVariants(english)];
  if (aliasGroup != null) {
    for (final part in aliasGroup.split(',')) {
      out.addAll(expandSlashVariants(part.trim()));
    }
  }
  final seen = <String>{};
  return [
    for (final a in out)
      if (a.isNotEmpty && seen.add(normalizeFoodText(a))) a,
  ];
}

/// Crude singular form for matching ("rotis" → "roti", "eggs" → "egg").
String _singular(String t) =>
    t.length > 3 && t.endsWith('s') && !t.endsWith('ss')
    ? t.substring(0, t.length - 1)
    : t;

const _stopWords = {
  'with', 'and', 'of', 'the', 'a', 'an', 'in', 'ki', 'ka', 'ke', 'aur', //
  'homemade', 'home', 'made', 'style', 'fresh', 'plain',
};

Set<String> _contentTokens(String normalized) => {
  for (final t in normalized.split(' '))
    if (t.isNotEmpty && !_stopWords.contains(t)) _singular(t),
};

// ---------------------------------------------------------------------------
// Index, search and matching
// ---------------------------------------------------------------------------

class _Entry {
  _Entry(this.dish)
    : aliases = dishAliases(dish.name),
      full = normalizeFoodText(dish.name) {
    keys = [for (final a in aliases) normalizeFoodText(a)];
    tokens = full.split(' ').toSet();
    keyTokens = [for (final k in keys) _contentTokens(k)];
  }

  final IndianDish dish;
  final List<String> aliases;
  final String full;
  late final List<String> keys;
  late final Set<String> tokens;
  late final List<Set<String>> keyTokens;
}

class IndianDishHit {
  const IndianDishHit(this.dish, this.score);
  final IndianDish dish;

  /// 100 exact · 85 prefix · 60–70 all words · 40 contains · <30 partial.
  final double score;
}

/// A confident match for an AI-parsed item name.
class IndianDishMatch {
  const IndianDishMatch(this.dish, {required this.alias, required this.score});
  final IndianDish dish;

  /// The name/alias that matched.
  final String alias;

  /// 1.0 exact; otherwise the token overlap (Jaccard) ≥ [matchThreshold].
  final double score;
}

/// In-memory, read-only index over the dish list.
class IndianFoodIndex {
  IndianFoodIndex(List<IndianDish> dishes)
    : _entries = [for (final d in dishes) _Entry(d)];

  final List<_Entry> _entries;

  int get length => _entries.length;
  Iterable<IndianDish> get dishes => _entries.map((e) => e.dish);

  /// Minimum token overlap for [match] (tested; see indian_food_db_test).
  static const matchThreshold = 0.67;

  /// Instant search: exact > prefix > every word (prefix) > contains >
  /// some words. Queries shorter than 2 characters return nothing.
  List<IndianDishHit> search(String query, {int limit = 20}) {
    final q = normalizeFoodText(query);
    if (q.length < 2) return const [];
    final qt = q.split(' ');
    final hits = <(IndianDishHit, int)>[];
    for (final e in _entries) {
      var score = 0.0;
      for (final k in e.keys) {
        if (k == q) {
          score = 100;
          break;
        }
        if (k.startsWith(q) && score < 85) score = 85;
      }
      if (score < 60) {
        final all = qt.every((w) => e.tokens.any((t) => t.startsWith(w)));
        if (all) {
          score = 60 + 10 * (qt.length / e.tokens.length).clamp(0, 1);
        } else if (e.full.contains(q)) {
          score = 40;
        } else if (qt.length >= 2) {
          final m = qt
              .where((w) => e.tokens.any((t) => t.startsWith(w)))
              .length;
          if (m > 0) score = 25 * m / qt.length;
        }
      }
      if (score > 0) hits.add((IndianDishHit(e.dish, score), e.full.length));
    }
    hits.sort((a, b) {
      final s = b.$1.score.compareTo(a.$1.score);
      return s != 0 ? s : a.$2.compareTo(b.$2);
    });
    return [for (final h in hits.take(limit)) h.$1];
  }

  /// Conservative matcher for AI item names: exact name/alias match, or the
  /// item's words are a subset of a dish name's words (or vice versa) with
  /// overlap ≥ [matchThreshold]. Ambiguous ties between dishes with
  /// different energy return null. Never guesses across different dishes.
  IndianDishMatch? match(String itemName) {
    final q = normalizeFoodText(itemName);
    if (q.length < 2) return null;
    final qt = _contentTokens(q);
    if (qt.isEmpty) return null;
    final qKey = (qt.toList()..sort()).join(' ');
    // 1. Exact name / alias (stop words and plurals ignored).
    for (final e in _entries) {
      for (var i = 0; i < e.keys.length; i++) {
        final kt = e.keyTokens[i];
        if (e.keys[i] == q || (kt.toList()..sort()).join(' ') == qKey) {
          return IndianDishMatch(e.dish, alias: e.aliases[i], score: 1);
        }
      }
    }
    // 2. High token overlap, one side contained in the other.
    IndianDishMatch? best;
    var tie = false;
    for (final e in _entries) {
      for (var i = 0; i < e.keys.length; i++) {
        final kt = e.keyTokens[i];
        if (kt.isEmpty) continue;
        final inter = qt.intersection(kt).length;
        if (inter == 0) continue;
        final subset = inter == qt.length || inter == kt.length;
        if (!subset) continue;
        final j = inter / qt.union(kt).length;
        if (j < matchThreshold) continue;
        if (best == null || j > best.score) {
          best = IndianDishMatch(e.dish, alias: e.aliases[i], score: j);
          tie = false;
        } else if (j == best.score && best.dish.id != e.dish.id) {
          final a = best.dish.kcal;
          final b = e.dish.kcal;
          if ((a - b).abs() > 0.1 * (a > b ? a : b)) tie = true;
        }
      }
    }
    return tie ? null : best;
  }
}

/// Parses and indexes the CSV (entry point for `compute`).
IndianFoodIndex buildIndianFoodIndex(String csv) =>
    IndianFoodIndex(parseIndianFoodCsv(csv));
