import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/core/domain/free_slots.dart';
import 'package:athlete_os/features/integrations/domain/slot_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarEventView ev(String id, DateTime s, DateTime e, {bool busy = true}) =>
    CalendarEventView(
      id: id,
      calendarId: 'primary',
      title: id,
      start: s,
      end: e,
      isBusy: busy,
    );

void main() {
  final day = DateTime(2026, 10, 26); // Monday
  DateTime at(int h, [int m = 0]) =>
      DateTime(day.year, day.month, day.day, h, m);

  test(
    'suggestions avoid busy events (with buffer) and stay in waking hours',
    () {
      final events = [
        ev('standup', at(9), at(10)),
        ev('lunch', at(12), at(13)),
        ev('free-ish', at(14), at(15), busy: false),
      ];
      final slots = suggestSlots(
        dayKey: '2026-10-26',
        events: events,
        duration: const Duration(minutes: 60),
        wakeMinutes: 7 * 60,
        sleepMinutes: 22 * 60,
        now: DateTime(2026, 10, 25, 20),
        max: 20,
      );
      expect(slots, isNotEmpty);
      for (final s in slots) {
        expect(s.duration, const Duration(minutes: 60));
        expect(s.start.isBefore(at(7)), isFalse);
        expect(s.end.isAfter(at(22)), isFalse);
        // No conflict with busy events, including 10 min buffer.
        expect(conflictsFor(s, events), isEmpty);
        expect(s.overlaps(TimeInterval(at(8, 50), at(10, 10))), isFalse);
      }
      // A slot overlapping the transparent ("free") event is allowed.
      expect(
        slots.any((s) => s.overlaps(TimeInterval(at(14), at(15)))),
        isTrue,
      );
    },
  );

  test('no suggestions in the past', () {
    final slots = suggestSlots(
      dayKey: '2026-10-26',
      events: const [],
      duration: const Duration(minutes: 30),
      wakeMinutes: 7 * 60,
      sleepMinutes: 22 * 60,
      now: at(20, 5),
    );
    expect(slots.first.start, at(20, 15));
    expect(slots.every((s) => !s.end.isAfter(at(22))), isTrue);
    expect(
      suggestSlots(
        dayKey: '2026-10-26',
        events: const [],
        duration: const Duration(minutes: 30),
        wakeMinutes: 7 * 60,
        sleepMinutes: 22 * 60,
        now: at(23),
      ),
      isEmpty,
    );
  });

  test('fully booked day yields nothing', () {
    expect(
      suggestSlots(
        dayKey: '2026-10-26',
        events: [ev('all', at(6), at(23))],
        duration: const Duration(minutes: 30),
        wakeMinutes: 7 * 60,
        sleepMinutes: 22 * 60,
        now: DateTime(2026, 10, 25),
      ),
      isEmpty,
    );
  });

  test('conflict check before insert flags overlapping busy events only', () {
    final events = [
      ev('meeting', at(18), at(19)),
      ev('ooo', at(18), at(19), busy: false),
    ];
    final c = conflictsFor(TimeInterval(at(18, 30), at(19, 30)), events);
    expect(c.map((e) => e.id), ['meeting']);
    expect(conflictsFor(TimeInterval(at(19), at(20)), events), isEmpty);
  });

  test('sleep time after midnight extends the window', () {
    final w = wakingWindow('2026-10-26', 9 * 60, 60);
    expect(w.end, DateTime(2026, 10, 27, 1));
  });
}
