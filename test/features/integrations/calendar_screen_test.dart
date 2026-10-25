import 'package:athlete_os/features/integrations/presentation/calendar_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('without Google credentials the calendar says so honestly', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(
        const CalendarScreen(),
        db: db,
        now: DateTime(2026, 10, 23, 9, 10),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Awaiting credentials'), findsOneWidget);
    expect(find.text('Setup steps'), findsOneWidget);
    // No routine before calibration: a prompt, not a fake agenda.
    expect(
      find.text('Calibrate JARVIS to see your day as a timeline here.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
