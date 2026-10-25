/// Plain, persistence-independent models for strength training analytics.
library;

/// Hevy set types. Anything unknown is treated as `normal`.
abstract final class SetTypes {
  static const normal = 'normal';
  static const warmup = 'warmup';
  static const dropset = 'dropset';
  static const failure = 'failure';

  static String normalise(String? raw) {
    final v = (raw ?? '').trim().toLowerCase().replaceAll(
      RegExp(r'[\s_-]'),
      '',
    );
    return switch (v) {
      'warmup' || 'w' => warmup,
      'dropset' || 'drop' || 'd' => dropset,
      'failure' || 'f' => failure,
      _ => normal,
    };
  }
}

class StrengthSet {
  const StrengthSet({
    this.type = SetTypes.normal,
    this.weightKg,
    this.reps,
    this.distanceM,
    this.durationS,
    this.rpe,
  });

  final String type;
  final double? weightKg;
  final int? reps;
  final double? distanceM;
  final int? durationS;
  final double? rpe;

  bool get isWarmup => type == SetTypes.warmup;

  /// Working sets are every set except warm-ups.
  bool get isWorking => !isWarmup;

  /// weight × reps for loaded rep sets (0 for bodyweight/cardio sets).
  double get volumeKg {
    final w = weightKg ?? 0;
    final r = reps ?? 0;
    if (w <= 0 || r <= 0) return 0;
    return w * r;
  }
}

class ExerciseLog {
  const ExerciseLog({
    required this.name,
    required this.sets,
    this.templateId,
    this.muscleGroup,
    this.notes,
    this.supersetId,
  });

  final String name;
  final String? templateId;

  /// Primary muscle group when a mapping is known, otherwise null.
  final String? muscleGroup;
  final String? notes;
  final int? supersetId;
  final List<StrengthSet> sets;

  /// Stable key used to group the same exercise across sessions.
  String get key => exerciseKey(name);

  Iterable<StrengthSet> get workingSets => sets.where((s) => s.isWorking);
}

String exerciseKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class WorkoutLog {
  const WorkoutLog({
    required this.id,
    required this.title,
    required this.startAt,
    required this.localDate,
    required this.source,
    required this.exercises,
    this.endAt,
    this.notes,
    this.externalId,
  });

  final String id;
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String localDate;

  /// hevy | manual | csv
  final String source;
  final String? externalId;
  final String? notes;
  final List<ExerciseLog> exercises;

  Duration? get duration => endAt?.difference(startAt);
}
