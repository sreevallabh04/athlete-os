import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../core/util/redact.dart';
import '../../../data/repositories/water_repository.dart';
import '../data/surfaces_platform.dart';
import '../domain/water_queue.dart';

/// Moves water taps from the native queue into [WaterRepository].
///
/// Exactly-once by construction: each native entry id maps to a stable row
/// id (`stableId('surface_water', id)`) and the repository inserts with
/// insert-or-ignore, so an entry that is drained twice (ack lost when the
/// process died, two drains racing) still produces one water log. Entries
/// are acked only after they were stored (or rejected as malformed).
class WaterQueueDrainer {
  WaterQueueDrainer(this._platform, this._water, this._clock);
  final SurfacesPlatform _platform;
  final WaterRepository _water;
  final Clock _clock;

  Future<int>? _running;

  /// Row id used for a native entry id.
  static String rowIdFor(String nativeId) =>
      stableId('surface_water', nativeId);

  bool _again = false;

  /// Drains the queue; returns how many entries were processed. A call made
  /// while a drain is running joins it and triggers one more pass, so taps
  /// queued mid-drain are not left behind.
  Future<int> drain() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop();
  }

  Future<int> _loop() async {
    var total = 0;
    try {
      do {
        _again = false;
        total += await _drainOnce();
      } while (_again);
    } finally {
      _running = null;
    }
    return total;
  }

  Future<int> _drainOnce() async {
    final raw = await _platform.peekWaterQueue();
    if (raw.isEmpty) return 0;
    final now = _clock.now();
    final done = <String>[];
    var stored = 0;
    for (final r in raw) {
      final entry = QueuedWater.fromMap(r, now: now);
      if (entry == null) {
        // Malformed: drop it so it cannot block the queue forever.
        final id = r is Map ? r['id'] : null;
        if (id is String) done.add(id);
        continue;
      }
      try {
        await _water.add(
          entry.amountMl,
          source: entry.source,
          at: entry.at,
          id: rowIdFor(entry.id),
        );
        done.add(entry.id);
        stored++;
      } catch (e) {
        // Keep it queued; the next drain retries (idempotently).
        debugPrint('surface water drain: ${redactSecrets(e.toString())}');
      }
    }
    await _platform.ackWaterQueue(done);
    return stored;
  }
}

final waterQueueDrainerProvider = Provider<WaterQueueDrainer>(
  (ref) => WaterQueueDrainer(
    ref.watch(surfacesPlatformProvider),
    ref.watch(waterRepositoryProvider),
    ref.watch(clockProvider),
  ),
);
