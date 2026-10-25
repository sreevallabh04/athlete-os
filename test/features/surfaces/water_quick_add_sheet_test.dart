import 'package:athlete_os/features/surfaces/presentation/water_quick_add_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets('quick-add sheet logs the tapped amount once and closes', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 10, 26, 9);

    await tester.pumpWidget(
      testHarness(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showWaterQuickAddSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        db: db,
        now: now,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Log water'), findsOneWidget);
    expect(find.textContaining('Nothing logged yet'), findsOneWidget);
    for (final ml in quickAddWaterAmounts) {
      expect(find.text('+$ml'), findsOneWidget);
    }

    await tester.tap(find.text('+500'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.waterLogs).get();
    expect(rows, hasLength(1));
    expect(rows.single.amountMl, 500);
    expect(rows.single.source, 'manual');
    expect(rows.single.localDate, '2026-10-26');
    expect(find.text('Log water'), findsNothing, reason: 'sheet closed');
    expect(find.text('Logged 500 ml water'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
