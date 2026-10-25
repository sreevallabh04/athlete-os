import 'package:athlete_os/core/domain/free_slots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime t(int h, [int m = 0]) => DateTime(2026, 10, 26, h, m);
  final window = TimeInterval(t(8), t(20));

  test('no busy time returns the whole window', () {
    final slots = findFreeSlots(
      window: window,
      busy: [],
      minDuration: const Duration(minutes: 45),
    );
    expect(slots, [window]);
  });

  test('finds gaps between overlapping meetings and respects min duration', () {
    final slots = findFreeSlots(
      window: window,
      busy: [
        TimeInterval(t(9), t(10)),
        TimeInterval(t(9, 30), t(11)), // overlaps previous
        TimeInterval(t(11, 30), t(12)), // leaves a 30 min gap -> too short
        TimeInterval(t(13), t(19, 30)),
      ],
      minDuration: const Duration(minutes: 45),
    );
    expect(slots, [TimeInterval(t(8), t(9)), TimeInterval(t(12), t(13))]);
  });

  test('buffer pads busy intervals', () {
    final slots = findFreeSlots(
      window: window,
      busy: [TimeInterval(t(10), t(11))],
      minDuration: const Duration(minutes: 30),
      buffer: const Duration(minutes: 15),
    );
    expect(slots.first, TimeInterval(t(8), t(9, 45)));
    expect(slots.last, TimeInterval(t(11, 15), t(20)));
  });

  test('busy time outside the window is ignored', () {
    final slots = findFreeSlots(
      window: window,
      busy: [TimeInterval(t(6), t(7)), TimeInterval(t(21), t(22))],
      minDuration: const Duration(hours: 1),
    );
    expect(slots, [window]);
  });
}
