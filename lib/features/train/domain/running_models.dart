import 'dart:convert';

/// Normalised cardio sport types stored in `CardioActivities.sportType`.
abstract final class SportTypes {
  static const run = 'run';
  static const walk = 'walk';
  static const hike = 'hike';
  static const ride = 'ride';
  static const other = 'other';

  /// Maps a Strava `sport_type` / `type` to the app's normalised type.
  static String fromStrava(String? raw) => switch (raw) {
    'Run' || 'TrailRun' || 'VirtualRun' => run,
    'Walk' => walk,
    'Hike' => hike,
    'Ride' ||
    'VirtualRide' ||
    'EBikeRide' ||
    'MountainBikeRide' ||
    'GravelRide' ||
    'EMountainBikeRide' => ride,
    _ => other,
  };
}

/// One split (usually 1 km) of an activity.
class RunSplit {
  const RunSplit({
    required this.distanceM,
    required this.movingTimeS,
    this.elapsedTimeS,
    this.avgHr,
    this.elevDiffM,
  });

  final double distanceM;
  final int movingTimeS;
  final int? elapsedTimeS;
  final double? avgHr;
  final double? elevDiffM;

  /// Seconds per km, or null when the split is too short to be meaningful.
  double? get paceSPerKm => distanceM >= 100 && movingTimeS > 0
      ? movingTimeS / (distanceM / 1000)
      : null;

  Map<String, Object?> toJson() => {
    'distance_m': distanceM,
    'moving_time_s': movingTimeS,
    'elapsed_time_s': elapsedTimeS,
    'avg_hr': avgHr,
    'elev_diff_m': elevDiffM,
  };

  static RunSplit? fromJson(Object? json) {
    if (json is! Map) return null;
    final d = (json['distance_m'] as num?)?.toDouble();
    final t = (json['moving_time_s'] as num?)?.toInt();
    if (d == null || t == null) return null;
    return RunSplit(
      distanceM: d,
      movingTimeS: t,
      elapsedTimeS: (json['elapsed_time_s'] as num?)?.toInt(),
      avgHr: (json['avg_hr'] as num?)?.toDouble(),
      elevDiffM: (json['elev_diff_m'] as num?)?.toDouble(),
    );
  }

  static List<RunSplit> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map(RunSplit.fromJson).whereType<RunSplit>().toList();
    } on FormatException {
      return const [];
    }
  }

  static String listToJson(List<RunSplit> splits) =>
      jsonEncode([for (final s in splits) s.toJson()]);
}

/// A cardio activity independent of storage, used by analytics and UI.
class RunActivity {
  const RunActivity({
    required this.id,
    required this.source,
    required this.sportType,
    required this.startAt,
    required this.localDate,
    this.externalId,
    this.name,
    this.distanceM,
    this.movingTimeS,
    this.elapsedTimeS,
    this.avgHr,
    this.maxHr,
    this.elevationGainM,
    this.splits = const [],
    this.fetchedAt,
    this.alsoInHealthConnect = false,
    this.duplicateIds = const [],
  });

  final String id;

  /// strava | health_connect | manual
  final String source;
  final String? externalId;
  final String? name;
  final String sportType;
  final DateTime startAt;
  final String localDate;
  final double? distanceM;
  final int? movingTimeS;
  final int? elapsedTimeS;
  final double? avgHr;
  final double? maxHr;
  final double? elevationGainM;
  final List<RunSplit> splits;
  final DateTime? fetchedAt;

  /// True when a Health Connect copy of this run was hidden by dedupe.
  final bool alsoInHealthConnect;

  /// Local ids of hidden duplicates.
  final List<String> duplicateIds;

  bool get isRun => sportType == 'run';
  bool get isStrava => source == 'strava';

  /// Moving time when known, else elapsed time.
  int? get timeS => movingTimeS ?? elapsedTimeS;

  double? get paceSPerKm {
    final d = distanceM;
    final t = timeS;
    if (d == null || t == null || d < 100 || t <= 0) return null;
    return t / (d / 1000);
  }

  RunActivity copyWith({
    bool? alsoInHealthConnect,
    List<String>? duplicateIds,
  }) => RunActivity(
    id: id,
    source: source,
    externalId: externalId,
    name: name,
    sportType: sportType,
    startAt: startAt,
    localDate: localDate,
    distanceM: distanceM,
    movingTimeS: movingTimeS,
    elapsedTimeS: elapsedTimeS,
    avgHr: avgHr,
    maxHr: maxHr,
    elevationGainM: elevationGainM,
    splits: splits,
    fetchedAt: fetchedAt,
    alsoInHealthConnect: alsoInHealthConnect ?? this.alsoInHealthConnect,
    duplicateIds: duplicateIds ?? this.duplicateIds,
  );
}
