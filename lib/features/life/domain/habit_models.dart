/// Pure habit models shared by the habit engine, repositories and UI.
library;

import '../../../core/time/clock.dart';

enum HabitScheduleType {
  daily('daily', 'Every day'),
  weekly('weekly', 'Times per week'),
  custom('custom', 'Specific days');

  const HabitScheduleType(this.key, this.label);
  final String key;
  final String label;

  static HabitScheduleType fromKey(String key) => switch (key) {
    'weekly' => weekly,
    'custom' => custom,
    _ => daily,
  };
}

enum HabitStatus {
  done('done'),
  skipped('skipped');

  const HabitStatus(this.key);
  final String key;

  static HabitStatus? fromKey(String? key) => switch (key) {
    'done' => done,
    'skipped' => skipped,
    _ => null,
  };
}

enum HabitCategory {
  health('health', 'Health'),
  fitness('fitness', 'Fitness'),
  nutrition('nutrition', 'Nutrition'),
  mind('mind', 'Mind'),
  productivity('productivity', 'Productivity'),
  other('other', 'Other');

  const HabitCategory(this.key, this.label);
  final String key;
  final String label;

  static HabitCategory fromKey(String key) =>
      values.firstWhere((c) => c.key == key, orElse: () => other);
}

/// Bit for an ISO weekday (Mon = 1 → bit 0 … Sun = 7 → bit 6).
int weekdayBit(int weekday) => 1 << (weekday - 1);

const int allDaysMask = 127;
const List<String> weekdayShort = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
const List<String> weekdayLetter = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

bool maskHasWeekday(int mask, int weekday) => mask & weekdayBit(weekday) != 0;

/// Human readable description of a days mask, e.g. "Mon, Wed, Fri".
String describeDaysMask(int mask) {
  if (mask & allDaysMask == allDaysMask) return 'Every day';
  if (mask & allDaysMask == 0x1F) return 'Weekdays';
  if (mask & allDaysMask == 0x60) return 'Weekends';
  final days = [
    for (var d = 1; d <= 7; d++)
      if (maskHasWeekday(mask, d)) weekdayShort[d - 1],
  ];
  return days.isEmpty ? 'No days' : days.join(', ');
}

/// When a habit is expected to happen.
class HabitSchedule {
  const HabitSchedule({
    required this.type,
    this.daysMask = allDaysMask,
    this.targetPerWeek = 3,
  });

  const HabitSchedule.daily()
    : type = HabitScheduleType.daily,
      daysMask = allDaysMask,
      targetPerWeek = 7;

  const HabitSchedule.weekly(this.targetPerWeek)
    : type = HabitScheduleType.weekly,
      daysMask = allDaysMask;

  const HabitSchedule.custom(this.daysMask)
    : type = HabitScheduleType.custom,
      targetPerWeek = 7;

  final HabitScheduleType type;
  final int daysMask;

  /// Only meaningful for [HabitScheduleType.weekly]; clamped to 1..7.
  final int targetPerWeek;

  int get weeklyTarget => targetPerWeek.clamp(1, 7);

  bool get isWeekly => type == HabitScheduleType.weekly;

  /// Whether [dateKey] is a scheduled day for daily/custom habits. Weekly
  /// habits are flexible: every day is eligible.
  bool isScheduledDay(String dateKey) => switch (type) {
    HabitScheduleType.daily || HabitScheduleType.weekly => true,
    HabitScheduleType.custom => maskHasWeekday(
      daysMask,
      LocalDates.parse(dateKey).weekday,
    ),
  };

  String describe() => switch (type) {
    HabitScheduleType.daily => 'Every day',
    HabitScheduleType.weekly => '$weeklyTarget× per week',
    HabitScheduleType.custom => describeDaysMask(daysMask),
  };
}

/// Effective state of a habit on one day. Manual marks always win over
/// automatic ones.
class DayMark {
  const DayMark(this.status, {this.auto = false});
  const DayMark.done({this.auto = false}) : status = HabitStatus.done;
  const DayMark.skipped() : status = HabitStatus.skipped, auto = false;

  final HabitStatus status;

  /// True when the completion came from an automatic rule (e.g. water goal
  /// reached) rather than the user.
  final bool auto;

  bool get isDone => status == HabitStatus.done;
  bool get isSkipped => status == HabitStatus.skipped;

  @override
  bool operator ==(Object other) =>
      other is DayMark && other.status == status && other.auto == auto;

  @override
  int get hashCode => Object.hash(status, auto);

  @override
  String toString() => 'DayMark(${status.key}${auto ? ', auto' : ''})';
}

/// Parses the JSON-stored reminder times (minutes after midnight).
List<int> parseReminderTimes(Object? decoded) {
  if (decoded is! List) return const [];
  final out = <int>{};
  for (final v in decoded) {
    if (v is num) {
      final m = v.toInt();
      if (m >= 0 && m < 1440) out.add(m);
    }
  }
  return out.toList()..sort();
}

/// "07:30" for 450 minutes.
String formatMinutes(int minutes) {
  final m = minutes % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}
