import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/presentation/ai_provider_settings_screen.dart';
import 'package:athlete_os/features/coach/presentation/coach_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  testWidgets('unconfigured backend shows setup banner and never answers', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(
        const CoachScreen(initialPrompt: 'How many steps left?'),
        db: db,
        now: testNow,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('AI backend not configured'), findsOneWidget);
    expect(find.text('Set up'), findsOneWidget);
    // Prefilled from ?prompt=, but sending is disabled.
    expect(find.text('How many steps left?'), findsWidgets);
    final send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_upward),
    );
    expect(send.onPressed, isNull);
    expect(find.text('Plan a 45-min workout slot today'), findsOneWidget);
    await _settle(tester);
  });

  testWidgets('ready backend enables the composer and hides the banner', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    final backend = FakeAiBackend([]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(db, now: testNow),
          aiBackendClientProvider.overrideWithValue(backend),
        ],
        child: const MaterialApp(home: CoachScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('AI backend not configured'), findsNothing);
    await tester.enterText(find.byType(TextField), 'hello coach');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(backend.requests, hasLength(1));
    expect(find.text('hello coach'), findsOneWidget);
    expect(find.text('done'), findsOneWidget);
    await _settle(tester);
  });

  testWidgets('settings screen shows the setup guide when unconfigured', (
    tester,
  ) async {
    final db = newTestDb();
    addTearDown(db.close);
    await tester.pumpWidget(
      testHarness(const AiProviderSettingsScreen(), db: db, now: testNow),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Awaiting credentials'), findsOneWidget);
    await _settle(tester);
  });
}
