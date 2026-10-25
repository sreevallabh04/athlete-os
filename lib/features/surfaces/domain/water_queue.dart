/// Water taps queued natively by the home-screen widget / Quick Settings tile
/// while the Flutter engine was not running. Pure Dart parsing (unit-tested).
library;

/// Sources a queued entry may claim; anything else is stored as `widget`.
const surfaceWaterSources = {'widget', 'qs_tile'};

/// Largest single entry accepted from the native queue (matches the widget's
/// fixed +250 ml with headroom; the repository caps at 5000).
const maxQueuedWaterMl = 2000;

class QueuedWater {
  const QueuedWater({
    required this.id,
    required this.amountMl,
    required this.at,
    required this.source,
  });

  /// Native idempotency id (unique per tap).
  final String id;
  final int amountMl;
  final DateTime at;
  final String source;

  /// Parses one native entry; null when malformed (it is then dropped).
  static QueuedWater? fromMap(Object? raw, {required DateTime now}) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final ml = raw['ml'];
    final at = raw['at'];
    final source = raw['source'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) return null;
    if (ml is! int || ml <= 0 || ml > maxQueuedWaterMl) return null;
    if (at is! int || at <= 0) return null;
    var t = DateTime.fromMillisecondsSinceEpoch(at);
    // Clock skew guard: never log into the future.
    if (t.isAfter(now)) t = now;
    return QueuedWater(
      id: id,
      amountMl: ml,
      at: t,
      source: surfaceWaterSources.contains(source)
          ? source as String
          : 'widget',
    );
  }
}
