// Parser for Hevy's official CSV export (Settings → Export data).
// Tolerant to column order, quoted fields, CRLF line endings and missing
// optional columns. Pure and unit-tested.
import 'workout_draft.dart';
import 'strength_models.dart';

class CsvImportResult {
  const CsvImportResult({required this.workouts, required this.warnings});
  final List<CsvWorkout> workouts;
  final List<String> warnings;
}

class CsvWorkout {
  const CsvWorkout({required this.externalKey, required this.draft});

  /// `title|start_time` exactly as in the file; hashed with
  /// `stableId('csv', …)` for idempotent imports.
  final String externalKey;
  final WorkoutDraft draft;
}

/// RFC 4180-ish CSV tokenizer.
List<List<String>> parseCsvRows(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  final s = input.startsWith('﻿') ? input.substring(1) : input;
  while (i < s.length) {
    final c = s[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
      } else {
        field.write(c);
      }
    } else {
      if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\n' || c == '\r') {
        row.add(field.toString());
        field.clear();
        if (row.any((f) => f.trim().isNotEmpty)) rows.add(row);
        row = <String>[];
        if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      } else {
        field.write(c);
      }
    }
    i++;
  }
  row.add(field.toString());
  if (row.any((f) => f.trim().isNotEmpty)) rows.add(row);
  return rows;
}

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'sept': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses Hevy CSV timestamps. Supports ISO 8601 and Hevy's
/// "15 Oct 2025, 18:30" style. Times without an offset are device-local.
DateTime? parseHevyCsvTime(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  final iso = DateTime.tryParse(v);
  if (iso != null) return iso;
  final m = RegExp(
    r'^(\d{1,2})\s+([A-Za-z]{3,4})\w*\s+(\d{4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?$',
  ).firstMatch(v);
  if (m != null) {
    final month = _months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    var hour = int.parse(m.group(4)!);
    final ampm = m.group(7)?.toLowerCase();
    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;
    return DateTime(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      hour,
      int.parse(m.group(5)!),
      int.parse(m.group(6) ?? '0'),
    );
  }
  // "Oct 15, 2025, 6:30 PM"
  final m2 = RegExp(
    r'^([A-Za-z]{3,4})\w*\s+(\d{1,2}),?\s+(\d{4}),?\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])?$',
  ).firstMatch(v);
  if (m2 != null) {
    final month = _months[m2.group(1)!.toLowerCase()];
    if (month == null) return null;
    var hour = int.parse(m2.group(4)!);
    final ampm = m2.group(6)?.toLowerCase();
    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;
    return DateTime(
      int.parse(m2.group(3)!),
      month,
      int.parse(m2.group(2)!),
      hour,
      int.parse(m2.group(5)!),
    );
  }
  return null;
}

double? _num(String? v) {
  if (v == null) return null;
  final t = v.trim();
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// Parses a Hevy CSV export into workout drafts grouped by title+start_time.
CsvImportResult parseHevyCsv(String text) {
  final rows = parseCsvRows(text);
  final warnings = <String>[];
  if (rows.isEmpty) {
    return const CsvImportResult(
      workouts: [],
      warnings: ['The file is empty.'],
    );
  }
  final header = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(String name) => header.indexOf(name);
  final required = ['title', 'start_time', 'exercise_title'];
  final missing = required.where((r) => col(r) < 0).toList();
  if (missing.isNotEmpty) {
    return CsvImportResult(
      workouts: const [],
      warnings: [
        'Missing required column(s): ${missing.join(', ')}. '
            'Is this a Hevy workout export?',
      ],
    );
  }
  String? cell(List<String> r, String name) {
    final i = col(name);
    if (i < 0 || i >= r.length) return null;
    final v = r[i].trim();
    return v.isEmpty ? null : v;
  }

  final order = <String>[];
  final meta = <String, Map<String, String?>>{};
  final exercises = <String, List<String>>{};
  final exMeta = <String, Map<String, String?>>{};
  final sets = <String, List<(int?, SetDraft)>>{};

  for (var i = 1; i < rows.length; i++) {
    final r = rows[i];
    final title = cell(r, 'title');
    final start = cell(r, 'start_time');
    final exTitle = cell(r, 'exercise_title');
    if (title == null || start == null || exTitle == null) {
      warnings.add('Row ${i + 1}: missing title, start_time or exercise.');
      continue;
    }
    if (parseHevyCsvTime(start) == null) {
      warnings.add('Row ${i + 1}: unrecognised start_time "$start".');
      continue;
    }
    final wKey = '$title|$start';
    if (!meta.containsKey(wKey)) {
      order.add(wKey);
      meta[wKey] = {
        'title': title,
        'start': start,
        'end': cell(r, 'end_time'),
        'description': cell(r, 'description'),
      };
      exercises[wKey] = [];
    }
    final supersetId = cell(r, 'superset_id');
    final eKey = '$wKey|$exTitle|${supersetId ?? ''}';
    if (!exMeta.containsKey(eKey)) {
      exercises[wKey]!.add(eKey);
      exMeta[eKey] = {
        'name': exTitle,
        'notes': cell(r, 'exercise_notes'),
        'superset': supersetId,
      };
      sets[eKey] = [];
    }
    var weight = _num(cell(r, 'weight_kg'));
    final lbs = _num(cell(r, 'weight_lbs'));
    if (weight == null && lbs != null) weight = lbs * 0.45359237;
    final km = _num(cell(r, 'distance_km'));
    final miles = _num(cell(r, 'distance_miles'));
    final distanceM = km != null
        ? km * 1000
        : miles != null
        ? miles * 1609.344
        : null;
    sets[eKey]!.add((
      _num(cell(r, 'set_index'))?.toInt(),
      SetDraft(
        type: SetTypes.normalise(cell(r, 'set_type')),
        weightKg: weight,
        reps: _num(cell(r, 'reps'))?.round(),
        distanceM: distanceM,
        durationS: _num(cell(r, 'duration_seconds'))?.round(),
        rpe: _num(cell(r, 'rpe')),
      ),
    ));
  }

  final out = <CsvWorkout>[];
  for (final wKey in order) {
    final m = meta[wKey]!;
    final startAt = parseHevyCsvTime(m['start']!)!;
    final endAt = m['end'] == null ? null : parseHevyCsvTime(m['end']!);
    final exDrafts = <ExerciseDraft>[];
    for (final eKey in exercises[wKey]!) {
      final em = exMeta[eKey]!;
      final ss = [...sets[eKey]!]
        ..sort((a, b) => (a.$1 ?? 0).compareTo(b.$1 ?? 0));
      exDrafts.add(
        ExerciseDraft(
          name: em['name']!,
          notes: em['notes'],
          supersetId: int.tryParse(em['superset'] ?? ''),
          sets: [for (final s in ss) s.$2],
        ),
      );
    }
    out.add(
      CsvWorkout(
        externalKey: wKey,
        draft: WorkoutDraft(
          title: m['title']!,
          startAt: startAt,
          endAt: endAt,
          notes: m['description'],
          exercises: exDrafts,
        ),
      ),
    );
  }
  return CsvImportResult(workouts: out, warnings: warnings);
}
