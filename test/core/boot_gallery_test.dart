import 'package:athlete_os/app/app.dart';
import 'package:athlete_os/app/boot/boot_sequence.dart';
import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/app/router.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/features/devgallery/dev_gallery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  test('greeting is time-of-day aware and name-optional', () {
    expect(
      BootSequenceView.greetingFor(DateTime(2026, 1, 1, 8), 'Sreevallabh'),
      'Good morning, Sreevallabh.',
    );
    expect(
      BootSequenceView.greetingFor(DateTime(2026, 1, 1, 14), null),
      'Good afternoon.',
    );
    expect(
      BootSequenceView.greetingFor(DateTime(2026, 1, 1, 21), '  '),
      'Good evening.',
    );
    expect(
      BootSequenceView.greetingFor(DateTime(2026, 1, 1, 3), 'S'),
      'Good night, S.',
    );
  });

  testWidgets(
    'boot plays once, reports honest statuses, then reveals the app',
    (tester) async {
      BootGate.debugReset();
      final db = newTestDb();
      addTearDown(db.close);
      await IntegrationStatusRepository(db)
          .setStatus(Providers.aiBackend, ConnectionStates.needsSetup);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...testOverrides(db, now: DateTime(2026, 10, 25, 21)),
            bootSequenceEnabledProvider.overrideWithValue(true),
          ],
          child: const AthleteOsApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('Good evening.'), findsWidgets);
      expect(find.text('HEALTH CONNECT'), findsOneWidget);
      expect(find.text('NOT CONNECTED'), findsWidgets);
      expect(find.text('NEEDS SETUP'), findsOneWidget);
      // Never claims a connection that wasn't made.
      expect(find.text('ONLINE'), findsNothing);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(find.text('HEALTH CONNECT'), findsNothing);
      expect(find.byType(HudDock), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 10));
    },
  );

  testWidgets('tapping skips the boot sequence', (tester) async {
    BootGate.debugReset();
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: DateTime(2026, 10, 25, 9)),
          bootSequenceEnabledProvider.overrideWithValue(true),
        ],
        child: const AthleteOsApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('LOCAL DATA'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('dev gallery route renders every section', (tester) async {
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: DateTime(2026, 10, 25, 9)),
          routerProvider.overrideWith(
            (ref) => buildRouter(initialLocation: AppPaths.devGallery),
          ),
        ],
        child: const AthleteOsApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(DevGalleryScreen), findsOneWidget);
    for (final section in [
      'Surfaces',
      'Controls',
      'Assistant',
      'Overlays & haptics',
    ]) {
      await tester.scrollUntilVisible(
        find.text(section),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(section), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
