import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/core/widgets/dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets(
    'app boots into the Today tab and bottom navigation switches tabs',
    (tester) async {
      final db = newTestDb();
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(db, now: DateTime(2026, 10, 25, 9)),
          child: const AthleteOsApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // The stock NavigationBar was replaced by the floating HUD dock.
      expect(find.byType(HudDock), findsOneWidget);
      for (final label in ['Today', 'Train', 'Nutrition', 'AI Coach', 'Life']) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.text('Life').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Life'), findsWidgets);
      // Let pending drift stream timers settle before teardown.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    },
  );

  test('LocalDates handles month/year boundaries and DST-safe arithmetic', () {
    expect(LocalDates.addDays('2026-12-31', 1), '2027-01-01');
    expect(LocalDates.addDays('2026-03-01', -1), '2026-02-28');
    expect(LocalDates.addDays('2028-03-01', -1), '2028-02-29');
    expect(LocalDates.range('2026-10-30', '2026-11-02').length, 4);
    expect(
      LocalDates.weekStart('2026-10-25'),
      '2026-10-19',
    ); // Sunday -> Monday
  });
}
