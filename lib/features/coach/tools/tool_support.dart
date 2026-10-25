import 'package:intl/intl.dart';

import '../../../core/time/clock.dart';
import 'tool_args_validator.dart';

/// Inclusive local-date range (YYYY-MM-DD keys).
class DateRange {
  const DateRange(this.start, this.end);
  final String start;
  final String end;

  bool get isSingleDay => start == end;
  List<String> get days => LocalDates.range(start, end);
  int get length => days.length;

  Map<String, Object?> toJson() => {'start': start, 'end': end};
}

/// Resolves `date` or `start_date`/`end_date` arguments. Without either, the
/// range is the [defaultDays] days ending [today].
DateRange resolveRange(
  Map<String, Object?> args,
  String today, {
  int defaultDays = 1,
  int maxDays = 31,
}) {
  final date = args['date'] as String?;
  final start = args['start_date'] as String?;
  final end = args['end_date'] as String?;
  if (date != null) {
    if (start != null || end != null) {
      throw ArgumentError('Use either date or start_date/end_date, not both.');
    }
    return DateRange(date, date);
  }
  if (start != null || end != null) {
    final s = start ?? end!;
    final e = end ?? today;
    if (s.compareTo(e) > 0) {
      throw ArgumentError('start_date must be on or before end_date.');
    }
    // Checked arithmetically: a model-supplied range can span millennia and
    // must not be expanded day by day just to be rejected.
    if (_daysBetween(s, e) + 1 > maxDays) {
      throw ArgumentError('Date range is limited to $maxDays days.');
    }
    return DateRange(s, e);
  }
  return DateRange(LocalDates.addDays(today, -(defaultDays - 1)), today);
}

/// Calendar days from [start] to [end] (UTC dates, so DST cannot skew it).
int _daysBetween(String start, String end) {
  DateTime utc(String k) {
    final d = LocalDates.parse(k);
    return DateTime.utc(d.year, d.month, d.day);
  }

  return utc(end).difference(utc(start)).inDays;
}

/// Standard provenance block attached to every tool result so the model can
/// cite where facts came from and how fresh they are.
Map<String, Object?> provenance({
  required Iterable<String> sources,
  DateTime? asOf,
  DateRange? range,
  String? note,
}) {
  final s = sources.toSet().toList()..sort();
  return {
    'sources': s.isEmpty ? ['none'] : s,
    'as_of': ?asOf?.toUtc().toIso8601String(),
    'date_range': ?range?.toJson(),
    'note': ?note,
  };
}

/// Human label for a raw source key.
String sourceLabel(String key) => switch (key) {
  'health_connect' => 'Health Connect',
  'manual' => 'Manual entry',
  'hevy' => 'Hevy',
  'csv' => 'CSV import',
  'openfoodfacts' || 'open_food_facts' => 'Open Food Facts',
  'usda' => 'USDA FoodData Central',
  'custom' => 'Custom food',
  'ai_estimate' || 'ai' => 'AI estimate',
  'quick_add' => 'Quick add',
  'notification' => 'Notification quick-log',
  'google_calendar' => 'Google Calendar',
  _ => key,
};

double r1(num v) => (v * 10).roundToDouble() / 10;
double r2(num v) => (v * 100).roundToDouble() / 100;

String shortDate(String key) => DateFormat.MMMd().format(LocalDates.parse(key));

/// Label suffix describing a date/range argument for activity chips.
String chipRange(Map<String, Object?> args, DateTime now) {
  final date = args['date'] as String?;
  final start = args['start_date'] as String?;
  final end = args['end_date'] as String?;
  if (date != null && ToolArgsValidator.isValidDate(date)) {
    return shortDate(date);
  }
  if (start != null &&
      end != null &&
      ToolArgsValidator.isValidDate(start) &&
      ToolArgsValidator.isValidDate(end)) {
    return '${shortDate(start)}–${shortDate(end)}';
  }
  return shortDate(LocalDates.key(now));
}

/// Common date-argument schema fragments.
Map<String, Map<String, Object?>> dateRangeProps() => {
  'date': S.date('Single local date YYYY-MM-DD. Defaults to today.'),
  'start_date': S.date('Range start YYYY-MM-DD (inclusive).'),
  'end_date': S.date('Range end YYYY-MM-DD (inclusive). Defaults to today.'),
};

/// Strava API Policy §5.3: Strava data must never reach an AI model.
const stravaPolicyNotice = {
  'status': 'unavailable_by_policy',
  'policy': 'Strava API Agreement §5.3 (effective 2026-06-01)',
  'message':
      'Strava data cannot be shared with AI models. The user can open the '
      'activity in the Running screen for the on-device, rule-based analysis '
      '(pace, splits, heart-rate zones). Runs recorded via Health Connect or '
      'entered manually are available through get_running_activities.',
};
