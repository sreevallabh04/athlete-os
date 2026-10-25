import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/water_repository.dart';
import 'package:athlete_os/features/surfaces/application/water_queue_drainer.dart';
import 'package:athlete_os/features/surfaces/data/surfaces_platform.dart';
import 'package:athlete_os/features/surfaces/domain/water_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  final now = DateTime(2026, 10, 26, 14, 30);

  late AppDatabase db;
  late FakeSurfacesPlatform platform;
  late WaterQueueDrainer drainer;

  setUp(() {
    db = newTestDb();
    platform = FakeSurfacesPlatform();
    drainer = WaterQueueDrainer(
      platform,
      WaterRepository(db, FixedClock(now)),
      FixedClock(now),
    );
  });

  tearDown(() => db.close());

  Map<String, Object?> entry(
    String id, {
    int ml = 250,
    DateTime? at,
    String source = 'widget',
  }) => {
    'id': id,
    'ml': ml,
    'at': (at ?? now.subtract(const Duration(minutes: 10)))
        .millisecondsSinceEpoch,
    'source': source,
  };

  Future<List<WaterLog>> rows() => db.select(db.waterLogs).get();

  test('drains queued taps into water logs with source widget', () async {
    platform.queue.addAll([entry('w-1'), entry('w-2', source: 'qs_tile')]);

    expect(await drainer.drain(), 2);

    final r = await rows();
    expect(r, hasLength(2));
    expect(r.map((w) => w.amountMl), everyElement(250));
    expect(r.map((w) => w.source).toSet(), {'widget', 'qs_tile'});
    expect(r.every((w) => w.localDate == '2026-10-26'), isTrue);
    expect(platform.queue, isEmpty, reason: 'acked after storing');
  });

  test('same id drained twice (lost ack) logs exactly once', () async {
    platform
      ..dropAcks = true
      ..queue.add(entry('w-dup'));

    await drainer.drain();
    await drainer.drain();

    final r = await rows();
    expect(r, hasLength(1));
    expect(r.single.id, WaterQueueDrainer.rowIdFor('w-dup'));
  });

  test('duplicate entries in one batch log once', () async {
    platform.queue.addAll([entry('w-x'), entry('w-x')]);
    await drainer.drain();
    expect(await rows(), hasLength(1));
  });

  test('concurrent drains share one run', () async {
    platform
      ..dropAcks = true
      ..queue.add(entry('w-c'));
    await Future.wait([drainer.drain(), drainer.drain(), drainer.drain()]);
    expect(await rows(), hasLength(1));
  });

  test('tap time decides the day; future timestamps are clamped', () async {
    platform.queue.addAll([
      entry('w-late', at: DateTime(2026, 10, 25, 23, 50)),
      entry('w-future', at: now.add(const Duration(hours: 3))),
    ]);
    await drainer.drain();
    final byId = {for (final r in await rows()) r.id: r};
    expect(byId[WaterQueueDrainer.rowIdFor('w-late')]!.localDate, '2026-10-25');
    expect(
      byId[WaterQueueDrainer.rowIdFor('w-future')]!.localDate,
      '2026-10-26',
    );
    expect(
      byId[WaterQueueDrainer.rowIdFor('w-future')]!.loggedAt.isAfter(
        now.toUtc(),
      ),
      isFalse,
    );
  });

  test('malformed entries are dropped (acked) without logging', () async {
    platform.queue.addAll([
      entry('w-zero', ml: 0),
      entry('w-huge', ml: 9000),
      {'id': 'w-noat', 'ml': 250},
      {'id': 'bad id!', 'ml': 250, 'at': 1},
      entry('w-ok', source: 'something-else'),
    ]);
    expect(await drainer.drain(), 1);
    final r = await rows();
    expect(r, hasLength(1));
    expect(r.single.source, 'widget', reason: 'unknown source normalised');
    expect(platform.queue, isEmpty);
    expect(
      platform.acks.single,
      containsAll(['w-zero', 'w-huge', 'w-noat', 'bad id!', 'w-ok']),
    );
  });

  test('empty queue is a no-op', () async {
    expect(await drainer.drain(), 0);
    expect(platform.acks, isEmpty);
  });

  test('QueuedWater.fromMap validation', () {
    expect(QueuedWater.fromMap('x', now: now), isNull);
    expect(QueuedWater.fromMap(entry('ok-1'), now: now)?.amountMl, 250);
    expect(
      QueuedWater.fromMap(entry('a' * 65), now: now),
      isNull,
      reason: 'id too long',
    );
  });
}
