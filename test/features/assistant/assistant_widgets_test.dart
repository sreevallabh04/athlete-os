import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/presentation/assistant_audit_screen.dart';
import 'package:athlete_os/features/assistant/presentation/assistant_screen.dart';
import 'package:athlete_os/features/assistant/presentation/assistant_settings_screen.dart';
import 'package:athlete_os/features/assistant/presentation/capabilities_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'assistant_test_utils.dart';

Future<void> pumpUntil(WidgetTester tester, bool Function() cond) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (cond()) return;
  }
  expect(cond(), isTrue, reason: 'condition not met in time');
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  late AppDatabase db;
  late FakeAssistantPlatform fake;

  setUp(() {
    db = newTestDb();
    fake = FakeAssistantPlatform();
  });
  tearDown(() async {
    await fake.dispose();
    await db.close();
  });

  Widget app(Widget child) => ProviderScope(
    overrides: assistantOverrides(db, fake),
    child: MaterialApp(theme: AppTheme.dark(), home: child),
  );

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('notification access is requested only after an explanation', (
    tester,
  ) async {
    tallScreen(tester);
    await tester.pumpWidget(app(const AssistantScreen()));
    await pumpUntil(tester, () => find.text('Set up').evaluate().isNotEmpty);

    // Declining the explanation never opens system settings.
    await tester.tap(find.text('Set up'));
    await pumpUntil(
      tester,
      () => find.text('Allow notification access?').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 700)); // sheet springs in
    expect(fake.openListenerSettingsCalls, 0);
    expect(find.textContaining('ONLY from the messaging'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(fake.openListenerSettingsCalls, 0);

    // Continuing opens it exactly once.
    await tester.tap(find.text('Set up'));
    await pumpUntil(
      tester,
      () => find.text('Open settings').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.text('Open settings'));
    await pumpUntil(tester, () => fake.openListenerSettingsCalls == 1);
    expect(fake.openListenerSettingsCalls, 1);
    await settle(tester);
  });

  testWidgets('a pending draft can be sent with one tap (user approval)', (
    tester,
  ) async {
    tallScreen(tester);
    final c = assistantContainer(db, fake);
    await tester.runAsync(() async {
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await c.read(ingestionServiceProvider).ingest([ev(text: 'Dinner at 8?')]);
      final d = (await c.read(assistantRepositoryProvider).allDrafts()).single;
      await c.read(replyServiceProvider).editDraft(d.id, 'Yes, see you');
    });
    c.dispose();

    await tester.pumpWidget(app(const AssistantScreen()));
    await pumpUntil(
      tester,
      () => find.text('Dinner at 8?').evaluate().isNotEmpty,
    );
    expect(find.text('Needs your reply'), findsOneWidget);
    expect(fake.sendCalls, isEmpty);

    final send = find.widgetWithText(HudButton, 'Send');
    expect(send, findsOneWidget);
    await tester.tap(send);
    await pumpUntil(tester, () => fake.sendCalls.isNotEmpty);
    expect(fake.sendCalls.single.text, 'Yes, see you');
    await pumpUntil(
      tester,
      () => find
          .textContaining('does not confirm delivery')
          .evaluate()
          .isNotEmpty,
    );
    await settle(tester);
  });

  testWidgets('the big kill switch updates the native config', (tester) async {
    tallScreen(tester);
    await tester.pumpWidget(app(const AssistantScreen()));
    await pumpUntil(
      tester,
      () => find.text('Emergency stop').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('kill_switch_button')));
    await pumpUntil(tester, () => fake.lastConfig?.killSwitch == true);
    await pumpUntil(
      tester,
      () => find.text('Resume assistant').evaluate().isNotEmpty,
    );
    expect(find.textContaining('Emergency stop is ON'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('settings explain the WhatsApp auto-reply block', (tester) async {
    tallScreen(tester);
    await tester.pumpWidget(app(const AssistantSettingsScreen()));
    await pumpUntil(tester, () => find.text('WhatsApp').evaluate().isNotEmpty);
    expect(find.textContaining('Terms of Service prohibit'), findsWidgets);
    expect(find.text('Draft (default)'), findsOneWidget);

    // Enabling the app writes it to the native allowlist.
    await tester.tap(find.byKey(const Key('app_enabled_com.whatsapp')));
    await pumpUntil(
      tester,
      () => fake.lastConfig?.enabledPackages.contains(whatsapp) ?? false,
    );
    await settle(tester);
  });

  testWidgets('capabilities list every capability incl. unused accessibility', (
    tester,
  ) async {
    tallScreen(tester);
    await tester.pumpWidget(app(const CapabilitiesScreen()));
    await pumpUntil(
      tester,
      () => find.text('Notification access').evaluate().isNotEmpty,
    );
    for (final t in [
      'Notification reply actions',
      'Post notifications',
      'Exact alarms',
      'Health Connect',
      'Battery optimization',
      'Assistant foreground service',
      'Camera',
      'Share sheet',
      'Open other apps',
      'Accessibility service — NOT used',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.textContaining('Allow background activity'), findsWidgets);

    // Battery: explanation first, then the system request.
    await tester.tap(find.text('Request exemption'));
    await pumpUntil(
      tester,
      () => find.text('Stop battery optimisation?').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(fake.requestBatteryCalls, 0);
    await tester.tap(find.text('Open settings'));
    await pumpUntil(tester, () => fake.requestBatteryCalls == 1);
    await settle(tester);
  });

  testWidgets('audit screen shows replies and a content-free timeline', (
    tester,
  ) async {
    tallScreen(tester);
    final c = assistantContainer(db, fake);
    await tester.runAsync(() async {
      await enableApp(c, whatsapp, label: 'WhatsApp');
      await c.read(ingestionServiceProvider).ingest([ev(text: 'Secret plan')]);
    });
    c.dispose();
    await tester.pumpWidget(app(const AssistantAuditScreen()));
    await pumpUntil(
      tester,
      () =>
          find.text('Timeline').evaluate().isNotEmpty &&
          find.textContaining('capture').evaluate().isNotEmpty,
    );
    expect(find.textContaining('Secret plan'), findsNothing);
    await settle(tester);
  });
}
