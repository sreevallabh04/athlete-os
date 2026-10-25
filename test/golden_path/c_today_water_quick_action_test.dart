import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/nutrition/presentation/hydration_screen.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:athlete_os/features/today/presentation/today_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import 'golden_helpers.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  testWidgets('Today +250 ml → exactly one 250 ml row → Hydration shows 250', (
    tester,
  ) async {
    useTallView(tester);
    final container = goldenContainer(db);

    await tester.pumpWidget(hostIn(container, const TodayScreen()));
    await pumpFrames(tester);
    expect(await db.select(db.waterLogs).get(), isEmpty);

    await tester.tap(find.text('+250 ml'));
    // Let the pulse animation, snackbar and every stream re-emission run.
    await pumpFrames(tester, count: 10);

    final rows = await db.select(db.waterLogs).get();
    expect(rows, hasLength(1), reason: 'one tap = one water_logs row');
    expect(rows.single.amountMl, 250);
    expect(rows.single.localDate, goldenToday);
    expect(rows.single.source, 'manual');
    expect(rows.single.deletedAt, isNull);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('2.75 L to go'), findsOneWidget); // 3,000 − 250

    final snap = await readAsync(
      tester,
      container,
      todaySnapshotProvider,
      until: (s) => s.waterMl > 0,
    );
    expect(snap.waterMl, 250);

    // Hydration screen in the same app state.
    await tester.pumpWidget(hostIn(container, const HydrationScreen()));
    await pumpFrames(tester, count: 4);
    final day = await readAsync(
      tester,
      container,
      waterDayProvider(goldenToday),
    );
    expect(day, hasLength(1));
    expect(day.fold<int>(0, (s, w) => s + w.amountMl), 250);
    expect(find.text('250 ml'), findsWidgets);
    expect(find.text('500 ml'), findsNothing, reason: 'not double-logged');
    expect(find.text('2.75 L to go'), findsOneWidget);

    await driftTeardown(tester);
  });
}
