/// Validates model-supplied tool arguments against the JSON Schema subset used
/// by our tool specs. Model output is untrusted input: anything not explicitly
/// allowed by the schema is rejected (including unknown properties).
///
/// Supported keywords: `type` (object, string, integer, number, boolean,
/// array), `properties`, `required`, `additionalProperties` (always treated as
/// false), `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `items`,
/// `minItems`, `maxItems`, and `format` (`date` = YYYY-MM-DD, `time` = HH:MM).
class ToolArgsValidator {
  const ToolArgsValidator();

  static final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _time = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  /// Returns a list of human-readable errors; empty means valid.
  List<String> validate(Map<String, Object?> schema, Object? value) {
    final errors = <String>[];
    _check(schema, value, r'$', errors);
    return errors;
  }

  void _check(
    Map<String, Object?> schema,
    Object? value,
    String path,
    List<String> errors,
  ) {
    final type = schema['type'] as String?;
    switch (type) {
      case 'object':
        if (value is! Map) {
          errors.add('$path must be an object');
          return;
        }
        final props =
            (schema['properties'] as Map?)?.cast<String, Object?>() ?? {};
        final required =
            (schema['required'] as List?)?.cast<String>() ?? const [];
        for (final r in required) {
          if (!value.containsKey(r) || value[r] == null) {
            errors.add('$path.$r is required');
          }
        }
        for (final entry in value.entries) {
          final key = entry.key.toString();
          final sub = props[key];
          if (sub == null) {
            errors.add('$path.$key is not an allowed property');
            continue;
          }
          if (entry.value == null && !required.contains(key)) continue;
          _check(
            (sub as Map).cast<String, Object?>(),
            entry.value,
            '$path.$key',
            errors,
          );
        }
        return;
      case 'array':
        if (value is! List) {
          errors.add('$path must be an array');
          return;
        }
        final minItems = schema['minItems'] as int?;
        final maxItems = schema['maxItems'] as int?;
        if (minItems != null && value.length < minItems) {
          errors.add('$path must have at least $minItems item(s)');
        }
        if (maxItems != null && value.length > maxItems) {
          errors.add('$path must have at most $maxItems item(s)');
        }
        final items = (schema['items'] as Map?)?.cast<String, Object?>();
        if (items != null) {
          for (var i = 0; i < value.length; i++) {
            _check(items, value[i], '$path[$i]', errors);
          }
        }
        return;
      case 'string':
        if (value is! String) {
          errors.add('$path must be a string');
          return;
        }
        final minLength = schema['minLength'] as int?;
        final maxLength = schema['maxLength'] as int?;
        if (minLength != null && value.length < minLength) {
          errors.add('$path must be at least $minLength characters');
        }
        if (maxLength != null && value.length > maxLength) {
          errors.add('$path must be at most $maxLength characters');
        }
        final format = schema['format'] as String?;
        if (format == 'date' && !isValidDate(value)) {
          errors.add('$path must be a valid date (YYYY-MM-DD)');
        }
        if (format == 'time' && !_time.hasMatch(value)) {
          errors.add('$path must be a time (HH:MM, 24 h)');
        }
        _checkEnum(schema, value, path, errors);
        return;
      case 'integer':
        if (value is! num || value != value.roundToDouble()) {
          errors.add('$path must be an integer');
          return;
        }
        _checkRange(schema, value, path, errors);
        _checkEnum(schema, value, path, errors);
        return;
      case 'number':
        if (value is! num || !value.isFinite) {
          errors.add('$path must be a number');
          return;
        }
        _checkRange(schema, value, path, errors);
        return;
      case 'boolean':
        if (value is! bool) errors.add('$path must be a boolean');
        return;
      default:
        errors.add('$path has an unsupported schema type "$type"');
    }
  }

  void _checkRange(
    Map<String, Object?> schema,
    num value,
    String path,
    List<String> errors,
  ) {
    final min = schema['minimum'] as num?;
    final max = schema['maximum'] as num?;
    if (min != null && value < min) errors.add('$path must be >= $min');
    if (max != null && value > max) errors.add('$path must be <= $max');
  }

  void _checkEnum(
    Map<String, Object?> schema,
    Object value,
    String path,
    List<String> errors,
  ) {
    final allowed = schema['enum'] as List?;
    if (allowed != null && !allowed.contains(value)) {
      errors.add('$path must be one of ${allowed.join(', ')}');
    }
  }

  /// Strict YYYY-MM-DD that is also a real calendar date.
  static bool isValidDate(String s) {
    if (!_date.hasMatch(s)) return false;
    final y = int.parse(s.substring(0, 4));
    final m = int.parse(s.substring(5, 7));
    final d = int.parse(s.substring(8, 10));
    if (m < 1 || m > 12 || d < 1) return false;
    final dt = DateTime.utc(y, m, d);
    return dt.year == y && dt.month == m && dt.day == d;
  }
}

/// Schema-building helpers so tool definitions stay compact and consistent.
abstract final class S {
  static Map<String, Object?> object(
    Map<String, Map<String, Object?>> properties, {
    List<String> required = const [],
  }) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };

  static Map<String, Object?> str(
    String description, {
    int? maxLength,
    int? minLength,
    List<String>? enumValues,
    String? format,
  }) => {
    'type': 'string',
    'description': description,
    'maxLength': ?maxLength,
    'minLength': ?minLength,
    'enum': ?enumValues,
    'format': ?format,
  };

  static Map<String, Object?> date(String description) =>
      str(description, format: 'date');

  static Map<String, Object?> integer(
    String description, {
    int? minimum,
    int? maximum,
  }) => {
    'type': 'integer',
    'description': description,
    'minimum': ?minimum,
    'maximum': ?maximum,
  };

  static Map<String, Object?> number(
    String description, {
    num? minimum,
    num? maximum,
  }) => {
    'type': 'number',
    'description': description,
    'minimum': ?minimum,
    'maximum': ?maximum,
  };

  static Map<String, Object?> boolean(String description) => {
    'type': 'boolean',
    'description': description,
  };

  static Map<String, Object?> array(
    String description,
    Map<String, Object?> items, {
    int? minItems,
    int? maxItems,
  }) => {
    'type': 'array',
    'description': description,
    'items': items,
    'minItems': ?minItems,
    'maxItems': ?maxItems,
  };
}
