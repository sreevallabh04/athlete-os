/// Removes anything that looks like a credential from text before it is
/// logged, stored as an error message, or shown to the user.
String redactSecrets(String input) {
  var out = input;
  final patterns = <RegExp>[
    RegExp(r'sk-ant-[A-Za-z0-9_\-]{10,}'),
    RegExp(r'sk-[A-Za-z0-9_\-]{16,}'),
    RegExp(r'AIza[0-9A-Za-z_\-]{20,}'),
    RegExp(r'bearer\s+[A-Za-z0-9._\-]{10,}', caseSensitive: false),
    RegExp(
      r'(api[_-]?key|access_token|refresh_token|client_secret|token|password)'
      r'''(["'\s:=]+)([^"'\s&,}]{6,})''',
      caseSensitive: false,
    ),
    RegExp(r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}'),
  ];
  for (final p in patterns) {
    out = out.replaceAllMapped(p, (m) {
      if (m.groupCount >= 3 && m.group(3) != null) {
        return '${m.group(1)}${m.group(2)}[REDACTED]';
      }
      return '[REDACTED]';
    });
  }
  return out;
}
