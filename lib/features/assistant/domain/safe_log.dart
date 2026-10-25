import 'package:flutter/foundation.dart';

import '../../../core/util/redact.dart';

/// Where [safeLog] writes. Replaceable in tests.
@visibleForTesting
void Function(String line) safeLogSink = debugPrint;

/// Metadata keys that may appear in assistant logs. Anything else is dropped.
const _allowedKeys = {
  'package',
  'status',
  'code',
  'mode',
  'action',
  'decision',
  'reasons',
  'flags',
  'count',
  'id',
  'kind',
  'trigger',
  'ms',
  'error',
  'from',
  'to',
  'conv',
  'enabled',
  'inserted',
  'duplicates',
  'ignored',
};

final _event = RegExp(r'^[a-z0-9_.]{1,48}$');
final _safeValue = RegExp(r'^[A-Za-z0-9_.:\-,/]{0,64}$');

/// The ONLY logging entry point of the assistant feature. Accepts an event
/// name and metadata (package names, statuses, codes, counts) — never message
/// text, contact names or credentials:
///  * unknown metadata keys are dropped,
///  * string values that are not short identifiers are replaced by their
///    length,
///  * the result is passed through [redactSecrets].
void safeLog(String event, [Map<String, Object?> meta = const {}]) {
  final name = _event.hasMatch(event) ? event : 'invalid_event';
  final parts = <String>['[assistant] $name'];
  meta.forEach((k, v) {
    if (!_allowedKeys.contains(k)) {
      parts.add('$k=<dropped>');
      return;
    }
    parts.add('$k=${_value(v)}');
  });
  safeLogSink(redactSecrets(parts.join(' ')));
}

String _value(Object? v) {
  if (v == null || v is num || v is bool) return '$v';
  if (v is Enum) return v.name;
  if (v is Iterable) return v.map(_value).join(',');
  final s = v is String ? v : v.runtimeType.toString();
  if (v is! String) return s;
  return _safeValue.hasMatch(s) ? s : '<redacted len=${s.length}>';
}

/// Exception summary safe for logs: type (and platform error code) only.
String errorCode(Object e) {
  final type = e.runtimeType.toString();
  try {
    final code = (e as dynamic).code;
    if (code is String && _safeValue.hasMatch(code)) return '$type:$code';
  } catch (_) {}
  return type;
}
