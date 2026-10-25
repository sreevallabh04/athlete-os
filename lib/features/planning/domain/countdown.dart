import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Loads the IANA timezone database once. Cheap after the first call.
void ensureTimeZonesInitialized() {
  if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
}

/// Resolves an IANA name to a location, or null when unknown. `UTC`/`GMT`
/// aliases are handled explicitly because the compact database omits them.
tz.Location? resolveTimeZone(String name) {
  ensureTimeZonesInitialized();
  final n = name.trim();
  if (const {'UTC', 'Etc/UTC', 'GMT', 'Etc/GMT', 'Z'}.contains(n)) {
    return tz.UTC;
  }
  try {
    return tz.getLocation(n);
  } catch (_) {
    return null;
  }
}

/// Whether [name] is a known IANA timezone.
bool isValidTimeZone(String name) => resolveTimeZone(name) != null;

/// A calendar date (no time, no zone).
class CalendarDate implements Comparable<CalendarDate> {
  const CalendarDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  /// Parses `YYYY-MM-DD`. Returns null for malformed or impossible dates
  /// (e.g. 2026-02-30).
  static CalendarDate? tryParse(String? key) {
    if (key == null) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final utc = DateTime.utc(y, mo, d);
    if (utc.year != y || utc.month != mo || utc.day != d) return null;
    return CalendarDate(y, mo, d);
  }

  /// Calendar days from this date to [other] (positive if [other] is later).
  /// Uses UTC midnights so DST never skews the count.
  int daysUntil(CalendarDate other) => DateTime.utc(
    other.year,
    other.month,
    other.day,
  ).difference(DateTime.utc(year, month, day)).inDays;

  String get key =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  @override
  int compareTo(CalendarDate other) => daysUntil(other).sign * -1;

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => key;
}

enum CountdownPhase { upcoming, today, past }

class CountdownResult {
  const CountdownResult({
    required this.eventDate,
    required this.todayInEventTz,
    required this.daysRemaining,
    required this.phase,
    required this.effectiveTzName,
    required this.usedFallbackTz,
    this.prepStart,
    this.progress,
  });

  final CalendarDate eventDate;

  /// "Today" as seen in the event's timezone (or the device fallback).
  final CalendarDate todayInEventTz;

  /// Positive when upcoming, 0 on the day, negative after the event.
  final int daysRemaining;
  final CountdownPhase phase;

  /// The timezone actually used; `null` means the device's local timezone.
  final String? effectiveTzName;

  /// True when the stored timezone was invalid and the device tz was used.
  final bool usedFallbackTz;
  final CalendarDate? prepStart;

  /// 0..1 progress from [prepStart] to the event. Null when no valid range.
  final double? progress;

  int get weeks => daysRemaining > 0 ? daysRemaining ~/ 7 : 0;
  int get remainderDays => daysRemaining > 0 ? daysRemaining % 7 : 0;
  int get daysSince => daysRemaining < 0 ? -daysRemaining : 0;

  /// Total prep length in days, when a prep start is known.
  int? get totalPrepDays => prepStart?.daysUntil(eventDate);

  /// "6 weeks 3 days", "1 week", "4 days", "Today", "12 days ago".
  String get weeksAndDaysLabel {
    switch (phase) {
      case CountdownPhase.today:
        return 'Today';
      case CountdownPhase.past:
        return daysSince == 1 ? '1 day ago' : '$daysSince days ago';
      case CountdownPhase.upcoming:
        final parts = <String>[
          if (weeks > 0) weeks == 1 ? '1 week' : '$weeks weeks',
          if (remainderDays > 0 || weeks == 0)
            remainderDays == 1 ? '1 day' : '$remainderDays days',
        ];
        return parts.join(' ');
    }
  }

  /// Short sentence used by Today and reports.
  String headline(String name) => switch (phase) {
    CountdownPhase.today => '$name is today',
    CountdownPhase.past =>
      '$name was $daysSince day${daysSince == 1 ? '' : 's'} ago',
    CountdownPhase.upcoming =>
      '$daysRemaining day${daysRemaining == 1 ? '' : 's'} to $name',
  };
}

/// Deterministic competition countdown.
///
/// The event is a calendar date in its own IANA timezone, so "days remaining"
/// is the number of calendar days between *today in the event's timezone* and
/// the event date — independent of where the device currently is.
abstract final class CompetitionCountdown {
  /// [now] is any instant (local or UTC). [prepStartDate] (YYYY-MM-DD, in the
  /// event timezone) overrides [createdAt] as the progress start.
  /// Throws [ArgumentError] if [eventDate] is not a valid YYYY-MM-DD date.
  static CountdownResult compute({
    required String eventDate,
    required String tzName,
    required DateTime now,
    String? prepStartDate,
    DateTime? createdAt,
  }) {
    final event = CalendarDate.tryParse(eventDate);
    if (event == null) {
      throw ArgumentError.value(eventDate, 'eventDate', 'expected YYYY-MM-DD');
    }
    final location = resolveTimeZone(tzName);

    CalendarDate dateIn(DateTime instant) {
      if (location != null) {
        final t = tz.TZDateTime.from(instant, location);
        return CalendarDate(t.year, t.month, t.day);
      }
      final l = instant.toLocal();
      return CalendarDate(l.year, l.month, l.day);
    }

    final today = dateIn(now);
    final days = today.daysUntil(event);
    final phase = days > 0
        ? CountdownPhase.upcoming
        : days == 0
        ? CountdownPhase.today
        : CountdownPhase.past;

    final start =
        CalendarDate.tryParse(prepStartDate) ??
        (createdAt != null ? dateIn(createdAt) : null);
    double? progress;
    if (start != null) {
      final total = start.daysUntil(event);
      if (total > 0) {
        progress = (start.daysUntil(today) / total).clamp(0.0, 1.0);
      } else if (phase != CountdownPhase.upcoming) {
        progress = 1.0;
      }
    }

    return CountdownResult(
      eventDate: event,
      todayInEventTz: today,
      daysRemaining: days,
      phase: phase,
      effectiveTzName: location == null
          ? null
          : (location == tz.UTC ? 'UTC' : location.name),
      usedFallbackTz: location == null,
      prepStart: start,
      progress: progress,
    );
  }
}

/// Common timezones offered by the competition timezone picker. The device
/// timezone is added at the top by the UI when it is known.
const commonTimeZones = <String>[
  'Asia/Kolkata',
  'Asia/Dubai',
  'Asia/Singapore',
  'Asia/Tokyo',
  'Australia/Sydney',
  'Europe/London',
  'Europe/Berlin',
  'Europe/Madrid',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'America/Sao_Paulo',
  'Africa/Johannesburg',
  'UTC',
];
