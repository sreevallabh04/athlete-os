import 'package:athlete_os/features/integrations/presentation/integrations_screen.dart';
import 'package:athlete_os/features/train/presentation/widgets/strava_branding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  testWidgets(
    'shows "Awaiting credentials" for Strava and Google when Env is empty',
    (tester) async {
      final db = newTestDb();
      addTearDown(db.close);
      await tester.pumpWidget(
        testHarness(
          const IntegrationsScreen(),
          db: db,
          now: DateTime(2026, 10, 25, 9),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Hevy'), findsOneWidget);
      expect(find.text('Add API key'), findsOneWidget);

      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byType(ConnectWithStravaButton),
        200,
        scrollable: list,
      );
      await tester.pump();
      expect(find.text('Strava'), findsOneWidget);
      // The branded Strava button is shown but disabled.
      final button = tester.widget<ConnectWithStravaButton>(
        find.byType(ConnectWithStravaButton),
      );
      expect(button.onPressed, isNull);
      expect(find.text('Awaiting credentials'), findsWidgets);

      await tester.scrollUntilVisible(
        find.text('Google Calendar'),
        200,
        scrollable: list,
      );
      await tester.pump();
      final google = find.ancestor(
        of: find.text('Google Calendar'),
        matching: find.byType(Column),
      );
      expect(
        find.descendant(
          of: google.first,
          matching: find.text('Awaiting credentials'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    },
  );
}
