/// Conservative keyword heuristic that decides whether to show a calm,
/// supportive card next to mood notes and journal entries.
///
/// This is NOT a diagnosis and never blocks saving. It only looks for clear,
/// first-person expressions of wanting to die or self-harm, and deliberately
/// ignores gym idioms ("I killed that workout", "suicide sprints",
/// "this set is killing me", "dying to try", "I hurt myself deadlifting").
library;

// Apostrophes are normalised to ' before matching; \x27 is that character.
final List<RegExp> _patterns = [
  // Injury phrasing ("I hurt myself deadlifting", "cut myself shaving") is
  // excluded: hurt/cut only count together with an intent verb.
  RegExp(r'\b(kill|killing|harm|harming)\s+myself\b'),
  RegExp(
    r'\b(want|wanna|going|thinking about|thought about|urge to)\s+(to\s+)?'
    r'(hurt|cut|harm)(ing)?\s+myself\b',
  ),
  RegExp(r'\bend(ing)?\s+(my|my own)\s+life\b'),
  RegExp(r'\btake\s+my\s+(own\s+)?life\b'),
  RegExp(r'\b(want|wanna|wish)\s+(to\s+)?(die|be dead)\b'),
  RegExp(r'\bi\s+wish\s+i\s+(was|were)\s+dead\b'),
  RegExp(r'\bbetter\s+off\s+dead\b'),
  RegExp(r'\bbetter\s+off\s+without\s+me\b'),
  RegExp(
    r'\b(do\s*n[o\x27]?t|dont|no longer)\s+want\s+to\s+(be\s+alive|live)\b',
  ),
  RegExp(r'\bno\s+(reason|point)\s+(to|in)\s+(live|living|going on)\b'),
  RegExp(r'\bend\s+it\s+all\b'),
  RegExp(r'\bsuicidal\b'),
  RegExp(
    r'\b(commit|committing|attempt|attempting|thinking about|thoughts of|'
    r'considering)\s+suicide\b',
  ),
  RegExp(r'\bsuicide\s+(attempt|plan|note|thoughts?)\b'),
  RegExp(r'\bself[\s-]?harm(ing)?\b'),
  RegExp(r'\bcan\s*(no|\x27)?t\s+go\s+on\s+(anymore|any more|living)\b'),
];

/// Returns true when [text] clearly expresses severe distress or danger.
bool detectsSevereDistress(String? text) {
  if (text == null || text.trim().isEmpty) return false;
  final normalised = text
      .toLowerCase()
      .replaceAll(RegExp('[‘’ʼ]'), "'")
      .replaceAll(RegExp(r'\s+'), ' ');
  return _patterns.any((p) => p.hasMatch(normalised));
}

/// Where people can find a local crisis line.
const crisisHelplineUrl = 'https://findahelpline.com';
