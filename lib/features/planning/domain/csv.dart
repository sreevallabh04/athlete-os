/// Minimal RFC 4180 CSV writer with spreadsheet formula-injection protection.
library;

String _cell(Object? v) {
  if (v == null) return '';
  if (v is num) return v.isFinite ? v.toString() : '';
  if (v is DateTime) return v.toUtc().toIso8601String();
  var s = v.toString();
  // Prevent spreadsheet apps from evaluating text cells as formulas.
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  if (s.contains(RegExp('[",\n\r]'))) s = '"${s.replaceAll('"', '""')}"';
  return s;
}

String toCsv(List<String> headers, Iterable<List<Object?>> rows) {
  final b = StringBuffer()..writeln(headers.map(_cell).join(','));
  for (final r in rows) {
    b.writeln(r.map(_cell).join(','));
  }
  return b.toString();
}
