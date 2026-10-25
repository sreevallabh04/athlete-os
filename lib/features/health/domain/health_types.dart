/// Plain-Dart model of the Health Connect data the app reads. Kept free of
/// plugin types so domain logic and tests never depend on the `health` plugin.
library;

/// Record types read from Health Connect (read access only).
enum HcDataType {
  steps('Steps'),
  distance('Distance'),
  activeCalories('Active calories'),
  totalCalories('Total calories'),
  exercise('Exercise sessions'),
  heartRate('Heart rate'),
  restingHeartRate('Resting heart rate'),
  sleepSession('Sleep'),
  weight('Weight');

  const HcDataType(this.label);
  final String label;
}

/// User-facing permission groups. The user enables a group; we then request
/// read access for exactly the [types] in that group and nothing else.
enum HealthGroup {
  activity(
    'Activity',
    'Steps, distance, active & total calories and exercise sessions. '
        'Used for the step coach, daily activity and importing runs, '
        'walks, hikes and rides.',
    [
      HcDataType.steps,
      HcDataType.distance,
      HcDataType.activeCalories,
      HcDataType.totalCalories,
      HcDataType.exercise,
    ],
  ),
  heart(
    'Heart',
    'Heart rate and resting heart rate. Shown as recent readings and used '
        'for average heart rate on imported cardio. Never used for medical '
        'diagnosis.',
    [HcDataType.heartRate, HcDataType.restingHeartRate],
  ),
  sleep(
    'Sleep',
    'Sleep sessions, used to show how long you slept each night.',
    [HcDataType.sleepSession],
  ),
  body(
    'Body',
    'Weight records (e.g. from a smart scale or Samsung Health), shown '
        'as a trend alongside your manual weigh-ins.',
    [HcDataType.weight],
  );

  const HealthGroup(this.label, this.description, this.types);
  final String label;
  final String description;
  final List<HcDataType> types;

  static HealthGroup? tryParse(String name) {
    for (final g in values) {
      if (g.name == name) return g;
    }
    return null;
  }

  static HealthGroup groupOf(HcDataType type) =>
      values.firstWhere((g) => g.types.contains(type));
}

/// Availability of the Health Connect provider on this device.
enum HcSdkStatus {
  available('Available'),
  needsInstall('Not installed'),
  needsUpdate('Update required'),
  unsupported('Not supported on this device');

  const HcSdkStatus(this.label);
  final String label;
}

/// One record read from Health Connect, normalised.
class HcRecord {
  const HcRecord({
    required this.uuid,
    required this.type,
    required this.value,
    required this.unit,
    required this.start,
    required this.end,
    required this.sourceApp,
    this.recordingMethod,
    this.metadata,
    this.workoutType,
    this.totalDistanceM,
    this.totalEnergyKcal,
    this.totalSteps,
  });

  /// Health Connect record id (`metadata.id`). For heart-rate series all
  /// samples of one record share the same uuid.
  final String uuid;
  final HcDataType type;
  final double value;
  final String unit;
  final DateTime start;
  final DateTime end;

  /// Package name of the app that wrote the record.
  final String sourceApp;

  /// manual | automatic | active | unknown
  final String? recordingMethod;
  final Map<String, Object?>? metadata;

  /// Health Connect / plugin workout type name, e.g. RUNNING.
  final String? workoutType;
  final double? totalDistanceM;
  final double? totalEnergyKcal;
  final double? totalSteps;

  Duration get duration => end.difference(start);
}

/// Sample/summary type keys used in the database (see tables.dart).
abstract final class HealthKeys {
  static const originHc = 'health_connect';
  static const originManual = 'manual';

  // DailyHealthSummaries.type
  static const steps = 'steps';
  static const distance = 'distance_m';
  static const activeMinutes = 'active_minutes';
  static const activeKcal = 'active_kcal';
  static const sleepMinutes = 'sleep_minutes';

  // HealthSamples.type
  static const heartRate = 'heart_rate';
  static const restingHeartRate = 'resting_heart_rate';
  static const weight = 'weight';
  static const sleepSession = 'sleep_session';
  static const exerciseSession = 'exercise_session';
}
