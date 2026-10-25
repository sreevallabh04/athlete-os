import 'package:athlete_os/features/today/domain/today_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime at(int h, [int m = 0]) => DateTime(2026, 10, 26, h, m);

  test('day phases switch at 04:00, 12:00 and 18:00', () {
    expect(dayPhaseOf(at(3, 59)), DayPhase.evening);
    expect(dayPhaseOf(at(4)), DayPhase.morning);
    expect(dayPhaseOf(at(11, 59)), DayPhase.morning);
    expect(dayPhaseOf(at(12)), DayPhase.day);
    expect(dayPhaseOf(at(17, 59)), DayPhase.day);
    expect(dayPhaseOf(at(18)), DayPhase.evening);
  });

  test('morning leads with the briefing and the session', () {
    final o = todaySectionOrder(at(6, 50));
    expect(o.take(2), [TodaySection.briefing, TodaySection.session]);
    expect(o.indexOf(TodaySection.review), o.length - 1);
  });

  test('daytime leads with targets and quick logging', () {
    final o = todaySectionOrder(at(13));
    expect(o.take(3), [
      TodaySection.briefing,
      TodaySection.targets,
      TodaySection.quickActions,
    ]);
  });

  test('evening leads with the review rituals', () {
    final o = todaySectionOrder(at(21, 40));
    expect(o[1], TodaySection.review);
    expect(
      o.indexOf(TodaySection.review),
      lessThan(o.indexOf(TodaySection.targets)),
    );
  });

  test('every section appears exactly once in every phase', () {
    for (final h in [6, 13, 21]) {
      for (final done in [false, true]) {
        final o = todaySectionOrder(at(h), sessionDone: done);
        expect(o.toSet(), TodaySection.values.toSet());
        expect(o.length, TodaySection.values.length);
      }
    }
  });

  test('a logged session drops below the vitals', () {
    final o = todaySectionOrder(at(6, 50), sessionDone: true);
    expect(o.indexOf(TodaySection.session), o.indexOf(TodaySection.vitals) + 1);
  });

  test('greeting uses the name and the time of day', () {
    expect(greetingFor(at(6), 'Sreevallabh'), 'Good morning, Sreevallabh.');
    expect(greetingFor(at(14), null), 'Good afternoon.');
    expect(greetingFor(at(21), ' '), 'Good evening.');
    expect(greetingFor(at(2), 'Sreevallabh'), 'Good night, Sreevallabh.');
  });
}
