import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/nutrition/application/providers.dart';
import 'package:athlete_os/features/surfaces/application/water_queue_drainer.dart';
import 'package:athlete_os/features/surfaces/data/surfaces_platform.dart';
import 'package:athlete_os/features/today/application/today_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import 'golden_helpers.dart';

void main() {
  late AppDatabase db;
  late FakeSurfacesPlatform platform;

  setUp(() {
    db = newTestDb();
    addTearDown(db.close);
    platform = FakeSurfacesPlatform();
  });

  /// One widget tap queued natively 10 minutes ago.
  Map<String, Object?> widgetTap(String id, {String source = 'widget'}) => {
    'id': id,
    'ml': 250,
    'at': goldenNow
        .subtract(const Duration(minutes: 10))
        .millisecondsSinceEpoch,
    'source': source,
  };

  ProviderContainer container() => goldenContainer(
    db,
    extra: [surfacesPlatformProvider.overrideWithValue(platform)],
  );

  Future<void> expectExactlyOne250(ProviderContainer c) async {
    final rows = await db.select(db.waterLogs).get();
    expect(rows, hasLength(1));
    expect(rows.single.amountMl, 250);
    expect(rows.single.source, 'widget');
    expect(rows.single.localDate, goldenToday);
    expect(rows.single.id, WaterQueueDrainer.rowIdFor('tap-1'));

    final day = await readFirst(
      c,
      waterDayProvider(goldenToday).future,
      waterDayProvider(goldenToday),
    );
    expect(day.fold<int>(0, (s, w) => s + w.amountMl), 250);
    final snap = await readFirst(
      c,
      todaySnapshotProvider.future,
      todaySnapshotProvider,
    );
    expect(snap.waterMl, 250);
  }

  test('queued widget tap drained twice → one water log', () async {
    platform.queue.add(widgetTap('tap-1'));
    final c = container();
    final drainer = c.read(waterQueueDrainerProvider);

    expect(await drainer.drain(), 1);
    expect(platform.queue, isEmpty, reason: 'acked after storing');
    expect(await drainer.drain(), 0);

    await expectExactlyOne250(c);
  });

  test('concurrent drains with a lost ack → one water log', () async {
    platform
      ..dropAcks =
          true // process died between insert and ack
      ..queue.add(widgetTap('tap-1'));
    final c = container();
    final drainer = c.read(waterQueueDrainerProvider);

    // Resume + "water queued" event + bootstrap all racing.
    await Future.wait([drainer.drain(), drainer.drain(), drainer.drain()]);
    // The entry is still queued (ack lost); a later drain must not re-log it.
    expect(platform.queue, hasLength(1));
    await drainer.drain();

    await expectExactlyOne250(c);
  });

  test('two drainer instances (provider rebuilt / new process) racing on '
      'the same queue → one water log', () async {
    platform
      ..dropAcks = true
      ..queue.add(widgetTap('tap-1'));
    final a = container();
    final b = container();

    await Future.wait([
      a.read(waterQueueDrainerProvider).drain(),
      b.read(waterQueueDrainerProvider).drain(),
    ]);
    await Future.wait([
      a.read(waterQueueDrainerProvider).drain(),
      b.read(waterQueueDrainerProvider).drain(),
    ]);

    await expectExactlyOne250(a);
  });
}
