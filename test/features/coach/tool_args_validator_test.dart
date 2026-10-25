import 'dart:convert';

import 'package:athlete_os/features/coach/tools/tool_args_validator.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const v = ToolArgsValidator();
  final schema = S.object(
    {
      'date': S.date('d'),
      'time': S.str('t', format: 'time'),
      'meal': S.str('m', enumValues: ['breakfast', 'lunch']),
      'name': S.str('n', minLength: 2, maxLength: 5),
      'count': S.integer('c', minimum: 1, maximum: 10),
      'grams': S.number('g', minimum: 0, maximum: 100),
      'flag': S.boolean('f'),
      'items': S.array(
        'i',
        S.object({'kcal': S.number('k')}, required: ['kcal']),
        minItems: 1,
        maxItems: 2,
      ),
    },
    required: ['meal'],
  );

  test('accepts valid arguments', () {
    expect(
      v.validate(schema, {
        'date': '2026-10-25',
        'time': '07:30',
        'meal': 'lunch',
        'name': 'egg',
        'count': 3,
        'grams': 12.5,
        'flag': true,
        'items': [
          {'kcal': 100},
        ],
      }),
      isEmpty,
    );
  });

  test('integer accepts whole doubles but not fractions', () {
    expect(v.validate(schema, {'meal': 'lunch', 'count': 3.0}), isEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'count': 3.5}), isNotEmpty);
  });

  test('rejects missing required, wrong types and unknown properties', () {
    expect(v.validate(schema, {}), contains(r'$.meal is required'));
    expect(
      v.validate(schema, {'meal': 'lunch', 'count': '3'}).single,
      contains('integer'),
    );
    expect(
      v.validate(schema, {'meal': 'lunch', 'hack': 1}).single,
      contains('not an allowed property'),
    );
    expect(
      v.validate(schema, {
        'meal': 'lunch',
        'items': [
          {'kcal': 1, 'x': 2},
        ],
      }).single,
      contains(r'$.items[0].x'),
    );
    expect(v.validate(schema, 'not an object'), isNotEmpty);
  });

  test('enforces enums, ranges, lengths and item counts', () {
    expect(v.validate(schema, {'meal': 'brunch'}).single, contains('one of'));
    expect(v.validate(schema, {'meal': 'lunch', 'count': 0}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'count': 11}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'grams': -1}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'name': 'a'}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'name': 'abcdef'}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'items': []}), isNotEmpty);
    expect(
      v.validate(schema, {
        'meal': 'lunch',
        'items': [
          {'kcal': 1},
          {'kcal': 2},
          {'kcal': 3},
        ],
      }),
      isNotEmpty,
    );
    expect(v.validate(schema, {'meal': 'lunch', 'flag': 'yes'}), isNotEmpty);
  });

  test('validates date and time formats strictly', () {
    for (final bad in ['2026-02-30', '2026-13-01', '26-10-25', '2026-1-05']) {
      expect(
        v.validate(schema, {'meal': 'lunch', 'date': bad}),
        isNotEmpty,
        reason: bad,
      );
    }
    expect(
      v.validate(schema, {'meal': 'lunch', 'date': '2028-02-29'}),
      isEmpty,
    );
    expect(v.validate(schema, {'meal': 'lunch', 'time': '24:00'}), isNotEmpty);
    expect(v.validate(schema, {'meal': 'lunch', 'time': '7:30'}), isNotEmpty);
  });

  test('every registered tool schema is tight and small enough', () {
    final names = <String>{};
    for (final t in coachTools) {
      expect(names.add(t.name), isTrue, reason: 'duplicate ${t.name}');
      expect(t.inputSchema['type'], 'object');
      expect(t.inputSchema['additionalProperties'], false);
      expect(
        utf8.encode(jsonEncode(t.inputSchema)).length,
        lessThan(4096),
        reason: t.name,
      );
      expect(RegExp(r'^[a-z_]{1,64}$').hasMatch(t.name), isTrue);
      // Empty args must be either valid or fail only on required fields.
      final errors = v.validate(t.inputSchema, {});
      expect(errors.every((e) => e.endsWith('is required')), isTrue);
    }
    expect(names, containsAll(['log_food', 'get_strava_activities']));
  });
}
