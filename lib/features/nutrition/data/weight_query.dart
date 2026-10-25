import 'package:drift/drift.dart';

import '../../../data/db/database.dart';

/// A body-weight reading with provenance.
class WeightPoint {
  const WeightPoint({
    required this.localDate,
    required this.at,
    required this.kg,
    required this.origin,
    this.sourceApp,
    this.sourceDevice,
  });

  final String localDate;
  final DateTime at;
  final double kg;

  /// health_connect | manual
  final String origin;
  final String? sourceApp;
  final String? sourceDevice;
}

/// Read-only view over `health_samples` where type = 'weight' (any origin).
/// The health feature owns writing these rows.
class WeightQuery {
  WeightQuery(this._db);
  final AppDatabase _db;

  Stream<List<WeightPoint>> watchRange(String start, String end) =>
      (_db.select(_db.healthSamples)
            ..where(
              (s) =>
                  s.type.equals('weight') &
                  s.localDate.isBetweenValues(start, end),
            )
            ..orderBy([(s) => OrderingTerm.asc(s.startAt)]))
          .watch()
          .map(
            (rows) => [
              for (final r in rows)
                WeightPoint(
                  localDate: r.localDate,
                  at: r.startAt,
                  kg: r.unit.toLowerCase() == 'lb'
                      ? r.value * 0.45359237
                      : r.value,
                  origin: r.origin,
                  sourceApp: r.sourceApp,
                  sourceDevice: r.sourceDevice,
                ),
            ],
          );
}
