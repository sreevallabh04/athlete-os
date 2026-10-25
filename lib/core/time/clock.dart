import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Injectable clock so time-dependent logic is testable.
class Clock {
  const Clock();
  DateTime now() => DateTime.now();
}

class FixedClock extends Clock {
  const FixedClock(this.fixed);
  final DateTime fixed;
  @override
  DateTime now() => fixed;
}

final clockProvider = Provider<Clock>((ref) => const Clock());

/// Calendar-date helpers. A "local date" is a YYYY-MM-DD key in the device's
/// current timezone at the moment of logging.
abstract final class LocalDates {
  static String key(DateTime t) {
    final l = t.isUtc ? t.toLocal() : t;
    return '${l.year.toString().padLeft(4, '0')}-'
        '${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  /// Parses a YYYY-MM-DD key to a local midnight DateTime.
  static DateTime parse(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static String addDays(String key, int days) {
    final d = parse(key);
    // Use calendar arithmetic (not Duration) to stay correct across DST.
    return LocalDates.key(DateTime(d.year, d.month, d.day + days));
  }

  /// Inclusive list of date keys from [start] to [end].
  static List<String> range(String start, String end) {
    final out = <String>[];
    var k = start;
    while (k.compareTo(end) <= 0) {
      out.add(k);
      k = addDays(k, 1);
    }
    return out;
  }

  /// Monday of the ISO week containing [key].
  static String weekStart(String key) {
    final d = parse(key);
    return addDays(key, -(d.weekday - DateTime.monday));
  }

  /// [start, end) instants of a local date.
  static (DateTime, DateTime) bounds(String key) {
    final d = parse(key);
    return (d, DateTime(d.year, d.month, d.day + 1));
  }
}
