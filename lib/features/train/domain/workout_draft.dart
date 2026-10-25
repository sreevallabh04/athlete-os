/// Source-agnostic workout content used to write Hevy, CSV and manual
/// workouts through a single repository method.
library;

class SetDraft {
  const SetDraft({
    this.type = 'normal',
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
}

class ExerciseDraft {
  const ExerciseDraft({
    required this.name,
    required this.sets,
    this.templateId,
    this.muscleGroup,
    this.notes,
    this.supersetId,
  });
  final String name;
  final String? templateId;
  final String? muscleGroup;
  final String? notes;
  final int? supersetId;
  final List<SetDraft> sets;
}

class WorkoutDraft {
  const WorkoutDraft({
    required this.title,
    required this.startAt,
    required this.exercises,
    this.endAt,
    this.notes,
  });
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String? notes;
  final List<ExerciseDraft> exercises;
}
