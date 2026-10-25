/// Men's Physique training program: typed model, deterministic generator,
/// deload/readiness rules, restriction substitution and run pace zones.
/// Pure Dart; persisted as JSON in AppSettings (`program.active`).
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Exercise library
// ---------------------------------------------------------------------------

/// Joint / body-part tags used to match recorded injuries.
abstract final class BodyPart {
  static const shoulder = 'shoulder';
  static const elbow = 'elbow';
  static const wrist = 'wrist';
  static const lowerBack = 'lower_back';
  static const knee = 'knee';
  static const hip = 'hip';
  static const ankle = 'ankle';
  static const neck = 'neck';

  /// Free-text synonyms → tag. Matched against restriction body part and
  /// description (lower-cased).
  static const synonyms = <String, String>{
    'shoulder': shoulder,
    'rotator': shoulder,
    'delt': shoulder,
    'elbow': elbow,
    'tennis elbow': elbow,
    'golfer': elbow,
    'wrist': wrist,
    'lower back': lowerBack,
    'low back': lowerBack,
    'lumbar': lowerBack,
    'back': lowerBack,
    'spine': lowerBack,
    'disc': lowerBack,
    'knee': knee,
    'acl': knee,
    'patella': knee,
    'hip': hip,
    'groin': hip,
    'ankle': ankle,
    'achilles': ankle,
    'shin': ankle,
    'neck': neck,
  };

  static Set<String> fromText(String text) {
    final t = text.toLowerCase();
    return {
      for (final e in synonyms.entries)
        if (t.contains(e.key)) e.value,
    };
  }
}

class ExerciseInfo {
  const ExerciseInfo({
    required this.name,
    required this.muscle,
    this.stress = const {},
    this.substitute,
    this.cue = '',
  });

  final String name;

  /// Primary muscle group (matches train feature's muscle names loosely).
  final String muscle;

  /// Joints loaded meaningfully by this movement.
  final Set<String> stress;

  /// Lower-stress alternative (name in [exerciseLibrary]).
  final String? substitute;
  final String cue;
}

const _lib = <ExerciseInfo>[
  // Chest
  ExerciseInfo(
    name: 'Incline Dumbbell Press',
    muscle: 'Chest',
    stress: {BodyPart.shoulder},
    substitute: 'Incline Machine Press',
    cue: '30° bench, elbows ~45°, stretch at the bottom.',
  ),
  ExerciseInfo(
    name: 'Incline Machine Press',
    muscle: 'Chest',
    substitute: 'Low-to-High Cable Fly',
    cue: 'Seat so handles line up with upper chest.',
  ),
  ExerciseInfo(
    name: 'Machine Chest Press',
    muscle: 'Chest',
    stress: {BodyPart.shoulder},
    substitute: 'Pec Deck',
    cue: 'Shoulder blades pinned, controlled 2-s lowering.',
  ),
  ExerciseInfo(
    name: 'Low-to-High Cable Fly',
    muscle: 'Chest',
    cue: 'Sweep up to chin height — upper-chest shelf.',
  ),
  ExerciseInfo(name: 'Pec Deck', muscle: 'Chest', cue: 'Soft elbows.'),
  // Shoulders
  ExerciseInfo(
    name: 'Seated Dumbbell Shoulder Press',
    muscle: 'Shoulders',
    stress: {BodyPart.shoulder, BodyPart.elbow},
    substitute: 'Cable Lateral Raise',
    cue: 'Slight incline backrest, stop just short of lockout.',
  ),
  ExerciseInfo(
    name: 'Machine Shoulder Press',
    muscle: 'Shoulders',
    stress: {BodyPart.shoulder},
    substitute: 'Cable Lateral Raise',
    cue: 'Neutral grip if available.',
  ),
  ExerciseInfo(
    name: 'Cable Lateral Raise',
    muscle: 'Shoulders',
    cue: 'Cable behind the body, lead with the elbow. The V-taper lift.',
  ),
  ExerciseInfo(
    name: 'Dumbbell Lateral Raise',
    muscle: 'Shoulders',
    substitute: 'Cable Lateral Raise',
    cue: 'Slight lean forward, pinkies level with thumbs.',
  ),
  ExerciseInfo(
    name: 'Reverse Pec Deck',
    muscle: 'Shoulders',
    cue: 'Rear delts: arms wide, no shrug.',
  ),
  ExerciseInfo(
    name: 'Face Pull',
    muscle: 'Shoulders',
    cue: 'Rope to forehead, external-rotate at the end.',
  ),
  // Back
  ExerciseInfo(
    name: 'Lat Pulldown (Wide Grip)',
    muscle: 'Lats',
    stress: {BodyPart.elbow},
    substitute: 'Single-Arm Cable Pulldown',
    cue: 'Drive elbows to the hips, chest tall.',
  ),
  ExerciseInfo(
    name: 'Pull-Up (Assisted if needed)',
    muscle: 'Lats',
    stress: {BodyPart.shoulder, BodyPart.elbow},
    substitute: 'Lat Pulldown (Wide Grip)',
    cue: 'Full hang, chest to bar intent.',
  ),
  ExerciseInfo(
    name: 'Single-Arm Cable Pulldown',
    muscle: 'Lats',
    cue: 'Kneeling, pull the elbow down and in.',
  ),
  ExerciseInfo(
    name: 'Chest-Supported T-Bar Row',
    muscle: 'Upper Back',
    substitute: 'Seated Cable Row (Wide Grip)',
    cue: 'Chest on pad protects the lower back.',
  ),
  ExerciseInfo(
    name: 'Seated Cable Row (Wide Grip)',
    muscle: 'Upper Back',
    cue: 'Pull to lower chest, pause 1 s.',
  ),
  ExerciseInfo(
    name: 'Straight-Arm Pulldown',
    muscle: 'Lats',
    cue: 'Arms long, hinge slightly, squeeze lats at the hips.',
  ),
  // Arms
  ExerciseInfo(
    name: 'Incline Dumbbell Curl',
    muscle: 'Biceps',
    stress: {BodyPart.elbow},
    substitute: 'Cable Curl',
    cue: 'Arms behind the torso for long-head stretch.',
  ),
  ExerciseInfo(
    name: 'EZ-Bar Curl',
    muscle: 'Biceps',
    stress: {BodyPart.wrist, BodyPart.elbow},
    substitute: 'Cable Curl',
    cue: 'No swinging; 2-s lowering.',
  ),
  ExerciseInfo(name: 'Cable Curl', muscle: 'Biceps', cue: 'Elbows fixed.'),
  ExerciseInfo(
    name: 'Overhead Cable Triceps Extension',
    muscle: 'Triceps',
    stress: {BodyPart.elbow, BodyPart.shoulder},
    substitute: 'Rope Pushdown',
    cue: 'Long-head stretch behind the head.',
  ),
  ExerciseInfo(
    name: 'Rope Pushdown',
    muscle: 'Triceps',
    cue: 'Split the rope at the bottom.',
  ),
  // Legs
  ExerciseInfo(
    name: 'Hack Squat',
    muscle: 'Quads',
    stress: {BodyPart.knee},
    substitute: 'Leg Press',
    cue: 'Full depth you can control; knees track toes.',
  ),
  ExerciseInfo(
    name: 'Romanian Deadlift',
    muscle: 'Hamstrings',
    stress: {BodyPart.lowerBack, BodyPart.hip},
    substitute: 'Seated Leg Curl',
    cue: 'Hips back, neutral spine, stop at mid-shin.',
  ),
  ExerciseInfo(
    name: 'Leg Press',
    muscle: 'Quads',
    stress: {BodyPart.knee},
    substitute: 'Leg Extension',
    cue: 'Feet mid-platform, don\'t round the lower back.',
  ),
  ExerciseInfo(
    name: 'Leg Extension',
    muscle: 'Quads',
    cue: 'Pause at the top.',
  ),
  ExerciseInfo(
    name: 'Seated Leg Curl',
    muscle: 'Hamstrings',
    cue: 'Lean forward slightly for a deeper stretch.',
  ),
  ExerciseInfo(
    name: 'Standing Calf Raise',
    muscle: 'Calves',
    stress: {BodyPart.ankle},
    substitute: 'Seated Calf Raise',
    cue: '2-s pause in the stretch.',
  ),
  ExerciseInfo(name: 'Seated Calf Raise', muscle: 'Calves'),
  // Core
  ExerciseInfo(
    name: 'Cable Crunch',
    muscle: 'Abs',
    stress: {BodyPart.lowerBack},
    substitute: 'Dead Bug',
    cue: 'Ribs to hips; don\'t pull with the arms.',
  ),
  ExerciseInfo(
    name: 'Hanging Knee Raise',
    muscle: 'Abs',
    stress: {BodyPart.shoulder},
    substitute: 'Dead Bug',
    cue: 'Posterior pelvic tilt at the top.',
  ),
  ExerciseInfo(
    name: 'Dead Bug',
    muscle: 'Abs',
    cue: 'Lower back stays flat on the floor.',
  ),
  ExerciseInfo(
    name: 'Stomach Vacuum + Posing Practice',
    muscle: 'Abs',
    cue: 'Front & back poses, 5 × 30-s vacuums. Men\'s Physique essentials.',
  ),
];

final Map<String, ExerciseInfo> exerciseLibrary = {
  for (final e in _lib) e.name: e,
};

// ---------------------------------------------------------------------------
// Program model
// ---------------------------------------------------------------------------

enum SessionKind {
  lift('lift'),
  run('run'),
  recovery('recovery');

  const SessionKind(this.key);
  final String key;
  static SessionKind fromKey(String? k) =>
      values.firstWhere((s) => s.key == k, orElse: () => lift);
}

class ExercisePlan {
  const ExercisePlan({
    required this.name,
    required this.sets,
    required this.repMin,
    required this.repMax,
    required this.rir,
    required this.restSeconds,
    this.note,
  });

  final String name;
  final int sets;
  final int repMin;
  final int repMax;

  /// Reps in reserve target.
  final int rir;
  final int restSeconds;
  final String? note;

  String get repRange => repMin == repMax ? '$repMin' : '$repMin–$repMax';
  ExerciseInfo? get info => exerciseLibrary[name];

  ExercisePlan copyWith({String? name, int? sets, int? rir, String? note}) =>
      ExercisePlan(
        name: name ?? this.name,
        sets: sets ?? this.sets,
        repMin: repMin,
        repMax: repMax,
        rir: rir ?? this.rir,
        restSeconds: restSeconds,
        note: note ?? this.note,
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'sets': sets,
    'repMin': repMin,
    'repMax': repMax,
    'rir': rir,
    'rest': restSeconds,
    'note': note,
  };

  static ExercisePlan fromJson(Map<dynamic, dynamic> m) => ExercisePlan(
    name: '${m['name']}',
    sets: (m['sets'] as num?)?.toInt() ?? 3,
    repMin: (m['repMin'] as num?)?.toInt() ?? 8,
    repMax: (m['repMax'] as num?)?.toInt() ?? 12,
    rir: (m['rir'] as num?)?.toInt() ?? 2,
    restSeconds: (m['rest'] as num?)?.toInt() ?? 90,
    note: m['note'] as String?,
  );
}

/// A run prescription. Paces are seconds per km (estimates from the goal).
class RunPlan {
  const RunPlan({
    required this.type,
    required this.minutes,
    required this.description,
    required this.paceMinS,
    required this.paceMaxS,
  });

  /// easy | intervals | tempo | goal_pace | time_trial
  final String type;
  final int minutes;
  final String description;
  final int paceMinS;
  final int paceMaxS;

  Map<String, Object> toJson() => {
    'type': type,
    'minutes': minutes,
    'description': description,
    'paceMinS': paceMinS,
    'paceMaxS': paceMaxS,
  };

  static RunPlan fromJson(Map<dynamic, dynamic> m) => RunPlan(
    type: '${m['type']}',
    minutes: (m['minutes'] as num?)?.toInt() ?? 30,
    description: '${m['description'] ?? ''}',
    paceMinS: (m['paceMinS'] as num?)?.toInt() ?? 420,
    paceMaxS: (m['paceMaxS'] as num?)?.toInt() ?? 465,
  );
}

class ProgramDay {
  const ProgramDay({
    required this.weekday,
    required this.kind,
    required this.title,
    required this.focus,
    required this.minutes,
    this.exercises = const [],
    this.run,
  });

  /// ISO weekday, Monday = 1.
  final int weekday;
  final SessionKind kind;
  final String title;
  final String focus;
  final int minutes;
  final List<ExercisePlan> exercises;
  final RunPlan? run;

  bool get isLift => kind != SessionKind.run;
  int get totalSets => exercises.fold(0, (s, e) => s + e.sets);

  ProgramDay copyWith({
    String? title,
    String? focus,
    int? minutes,
    List<ExercisePlan>? exercises,
    RunPlan? Function()? run,
  }) => ProgramDay(
    weekday: weekday,
    kind: kind,
    title: title ?? this.title,
    focus: focus ?? this.focus,
    minutes: minutes ?? this.minutes,
    exercises: exercises ?? this.exercises,
    run: run != null ? run() : this.run,
  );

  Map<String, Object?> toJson() => {
    'weekday': weekday,
    'kind': kind.key,
    'title': title,
    'focus': focus,
    'minutes': minutes,
    'exercises': [for (final e in exercises) e.toJson()],
    'run': run?.toJson(),
  };

  static ProgramDay fromJson(Map<dynamic, dynamic> m) => ProgramDay(
    weekday: (m['weekday'] as num?)?.toInt() ?? 1,
    kind: SessionKind.fromKey(m['kind'] as String?),
    title: '${m['title'] ?? ''}',
    focus: '${m['focus'] ?? ''}',
    minutes: (m['minutes'] as num?)?.toInt() ?? 60,
    exercises: [
      if (m['exercises'] is List)
        for (final e in m['exercises'] as List)
          if (e is Map) ExercisePlan.fromJson(e),
    ],
    run: m['run'] is Map ? RunPlan.fromJson(m['run'] as Map) : null,
  );
}

class PaceZones {
  const PaceZones({required this.goalPaceS});

  /// Goal race pace (s/km).
  final int goalPaceS;

  (int, int) get easy => (goalPaceS + 60, goalPaceS + 105);
  (int, int) get tempo => (goalPaceS + 15, goalPaceS + 30);
  (int, int) get interval => (goalPaceS - 15, goalPaceS - 5);
  (int, int) get goal => (goalPaceS, goalPaceS);

  static PaceZones fromGoal(int distanceM, int timeS) =>
      PaceZones(goalPaceS: (timeS / distanceM * 1000).round());
}

String formatPace(int secondsPerKm) =>
    '${secondsPerKm ~/ 60}:${(secondsPerKm % 60).toString().padLeft(2, '0')}';

String formatPaceRange(int a, int b) =>
    a == b ? '${formatPace(a)}/km' : '${formatPace(a)}–${formatPace(b)}/km';

class TrainingProgram {
  const TrainingProgram({
    required this.name,
    required this.startDate,
    required this.days,
    required this.runGoalDistanceM,
    required this.runGoalTimeS,
    this.deloadEvery = 6,
    this.deloadVolumeFactor = 0.6,
  });

  final String name;

  /// Monday (YYYY-MM-DD) of program week 1.
  final String startDate;

  /// Template week, Monday..Sunday (7 entries).
  final List<ProgramDay> days;
  final int runGoalDistanceM;
  final int runGoalTimeS;
  final int deloadEvery;
  final double deloadVolumeFactor;

  static const progressionRule =
      'Double progression: stay at a weight until every set reaches the top '
      'of the rep range at the target RIR, then add the smallest increment '
      '(2.5 kg barbell/machine, 1–2 kg dumbbells) and work back up from the '
      'bottom of the range.';

  PaceZones get paces => PaceZones.fromGoal(runGoalDistanceM, runGoalTimeS);

  int get liftDays => days.where((d) => d.isLift).length;
  int get runDays => days.where((d) => d.kind == SessionKind.run).length;

  /// 1-based program week for [dateKey] (week 1 = [startDate] week).
  int weekNumber(String dateKey) {
    final s = _parse(startDate);
    final d = _parse(dateKey);
    final diff = DateTime.utc(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime.utc(s.year, s.month, s.day)).inDays;
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
  }

  bool isDeloadWeek(int week) => deloadEvery > 0 && week % deloadEvery == 0;

  /// Session for [dateKey] with week-specific progression and deloads
  /// applied (restrictions/readiness are applied separately).
  ProgramDay sessionFor(String dateKey) {
    final weekday = _parse(dateKey).weekday;
    final week = weekNumber(dateKey);
    final base = days.firstWhere(
      (d) => d.weekday == weekday,
      orElse: () => days.first,
    );
    var day = base;
    if (day.kind == SessionKind.run) {
      day = day.copyWith(run: () => _runForWeek(day, week));
    }
    if (isDeloadWeek(week)) day = deload(day, deloadVolumeFactor);
    return day;
  }

  RunPlan _runForWeek(ProgramDay day, int week) {
    final z = paces;
    final isQuality = day.run?.type != 'easy';
    // Weeks completed excluding deloads → gentle ≤10 % weekly growth.
    final buildWeeks = week - 1 - (week - 1) ~/ deloadEvery;
    if (!isQuality) {
      final minutes = math.min(40, (30 * math.pow(1.1, buildWeeks)).floor());
      return RunPlan(
        type: 'easy',
        minutes: minutes,
        description:
            'Easy Zone 2: conversational, nose-breathing pace. '
            '$minutes min + 4 × 15-s relaxed strides.',
        paceMinS: z.easy.$1,
        paceMaxS: z.easy.$2,
      );
    }
    final slot = (week - 1) % deloadEvery % 5;
    return switch (slot) {
      0 => RunPlan(
        type: 'intervals',
        minutes: 35,
        description:
            '10-min easy warm-up · 6 × 400 m at interval pace with 90-s '
            'walk/jog · 8-min easy cool-down.',
        paceMinS: z.interval.$1,
        paceMaxS: z.interval.$2,
      ),
      1 => RunPlan(
        type: 'tempo',
        minutes: 36,
        description:
            '10-min easy · 3 × 6 min at tempo pace, 2-min easy jog between '
            '· 6-min cool-down.',
        paceMinS: z.tempo.$1,
        paceMaxS: z.tempo.$2,
      ),
      2 => RunPlan(
        type: 'intervals',
        minutes: 38,
        description:
            '10-min easy · 5 × 600 m at interval pace with 2-min jog · '
            '8-min cool-down.',
        paceMinS: z.interval.$1,
        paceMaxS: z.interval.$2,
      ),
      3 => RunPlan(
        type: 'tempo',
        minutes: 40,
        description:
            '10-min easy · 2 × 10 min at tempo pace, 3-min easy jog · '
            '7-min cool-down.',
        paceMinS: z.tempo.$1,
        paceMaxS: z.tempo.$2,
      ),
      _ => RunPlan(
        type: 'goal_pace',
        minutes: 40,
        description:
            '10-min easy · 4 × 1 km at goal 5K pace with 2-min jog · '
            'cool-down. Every 2nd block: 5K time trial instead.',
        paceMinS: z.goal.$1,
        paceMaxS: z.goal.$2,
      ),
    };
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'startDate': startDate,
    'runGoalDistanceM': runGoalDistanceM,
    'runGoalTimeS': runGoalTimeS,
    'deloadEvery': deloadEvery,
    'deloadVolumeFactor': deloadVolumeFactor,
    'days': [for (final d in days) d.toJson()],
  };

  static TrainingProgram? fromJson(Object? json) {
    if (json is! Map) return null;
    final days = [
      if (json['days'] is List)
        for (final d in json['days'] as List)
          if (d is Map) ProgramDay.fromJson(d),
    ];
    if (days.isEmpty) return null;
    return TrainingProgram(
      name: '${json['name'] ?? 'Program'}',
      startDate: '${json['startDate']}',
      days: days,
      runGoalDistanceM: (json['runGoalDistanceM'] as num?)?.toInt() ?? 5000,
      runGoalTimeS: (json['runGoalTimeS'] as num?)?.toInt() ?? 1800,
      deloadEvery: (json['deloadEvery'] as num?)?.toInt() ?? 6,
      deloadVolumeFactor:
          (json['deloadVolumeFactor'] as num?)?.toDouble() ?? 0.6,
    );
  }
}

DateTime _parse(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// Volume −40 % (sets × 0.6, min 1), +1 RIR; runs shortened and kept easy.
ProgramDay deload(ProgramDay day, [double factor = 0.6]) {
  final run = day.run;
  return day.copyWith(
    title: '${day.title} · Deload',
    minutes: (day.minutes * 0.75).round(),
    exercises: [
      for (final e in day.exercises)
        e.copyWith(
          sets: math.max(1, (e.sets * factor).round()),
          rir: e.rir + 1,
        ),
    ],
    run: run == null
        ? null
        : () => RunPlan(
            type: 'easy',
            minutes: (run.minutes * 0.7).round(),
            description: 'Deload week: easy running only, no intervals.',
            paceMinS: run.type == 'easy' ? run.paceMinS : run.paceMaxS + 60,
            paceMaxS: run.type == 'easy' ? run.paceMaxS : run.paceMaxS + 105,
          ),
  );
}

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

ExercisePlan _ex(
  String name,
  int sets,
  int repMin,
  int repMax, {
  int rir = 2,
  int rest = 90,
  String? note,
}) {
  assert(exerciseLibrary.containsKey(name), 'Unknown exercise $name');
  return ExercisePlan(
    name: name,
    sets: sets,
    repMin: repMin,
    repMax: repMax,
    rir: rir,
    restSeconds: rest,
    note: note,
  );
}

/// 7-day Men's Physique split: 5 lifting + 2 running sessions, early
/// morning, ~60–75 min. Emphasis: delts (esp. lateral), upper chest, lat
/// width, arms; legs at moderate volume (board shorts division).
TrainingProgram generateMensPhysiqueProgram({
  required String startMonday,
  int runGoalDistanceM = 5000,
  int runGoalTimeS = 1800,
}) {
  final z = PaceZones.fromGoal(runGoalDistanceM, runGoalTimeS);
  return TrainingProgram(
    name: 'Men\'s Physique · 5 lift + 2 run',
    startDate: startMonday,
    runGoalDistanceM: runGoalDistanceM,
    runGoalTimeS: runGoalTimeS,
    days: [
      ProgramDay(
        weekday: 1,
        kind: SessionKind.lift,
        title: 'Push',
        focus: 'Upper chest & shoulders',
        minutes: 70,
        exercises: [
          _ex('Incline Dumbbell Press', 4, 6, 10, rest: 150),
          _ex('Machine Chest Press', 3, 8, 12, rest: 120),
          _ex('Seated Dumbbell Shoulder Press', 3, 8, 12, rest: 120),
          _ex('Cable Lateral Raise', 4, 12, 20, rir: 1, rest: 60),
          _ex('Low-to-High Cable Fly', 3, 12, 15, rir: 1, rest: 75),
          _ex('Overhead Cable Triceps Extension', 3, 10, 15, rir: 1, rest: 75),
        ],
      ),
      ProgramDay(
        weekday: 2,
        kind: SessionKind.lift,
        title: 'Pull',
        focus: 'Lat width & upper back',
        minutes: 70,
        exercises: [
          _ex('Lat Pulldown (Wide Grip)', 4, 8, 12, rest: 120),
          _ex('Chest-Supported T-Bar Row', 4, 8, 12, rest: 120),
          _ex('Single-Arm Cable Pulldown', 3, 10, 15, rir: 1, rest: 75),
          _ex('Seated Cable Row (Wide Grip)', 3, 10, 12, rest: 90),
          _ex('Reverse Pec Deck', 3, 15, 20, rir: 1, rest: 60),
          _ex('Incline Dumbbell Curl', 3, 10, 12, rir: 1, rest: 75),
        ],
      ),
      ProgramDay(
        weekday: 3,
        kind: SessionKind.run,
        title: 'Easy run',
        focus: 'Zone 2 aerobic base',
        minutes: 40,
        run: RunPlan(
          type: 'easy',
          minutes: 30,
          description: 'Easy Zone 2, conversational pace.',
          paceMinS: z.easy.$1,
          paceMaxS: z.easy.$2,
        ),
      ),
      ProgramDay(
        weekday: 4,
        kind: SessionKind.lift,
        title: 'Legs + abs',
        focus: 'Moderate volume — quads, hamstrings, calves, core',
        minutes: 70,
        exercises: [
          _ex('Hack Squat', 3, 6, 10, rest: 180),
          _ex('Romanian Deadlift', 3, 8, 10, rest: 150),
          _ex('Leg Press', 2, 10, 15, rest: 120),
          _ex('Seated Leg Curl', 3, 10, 15, rir: 1, rest: 75),
          _ex('Standing Calf Raise', 3, 10, 15, rir: 1, rest: 60),
          _ex('Cable Crunch', 3, 10, 15, rir: 1, rest: 60),
          _ex('Hanging Knee Raise', 2, 10, 15, rir: 1, rest: 60),
        ],
      ),
      ProgramDay(
        weekday: 5,
        kind: SessionKind.lift,
        title: 'Upper · V-taper',
        focus: 'Shoulders, arms & width',
        minutes: 75,
        exercises: [
          _ex('Pull-Up (Assisted if needed)', 3, 6, 10, rest: 150),
          _ex('Machine Shoulder Press', 3, 8, 12, rest: 120),
          _ex('Dumbbell Lateral Raise', 4, 12, 20, rir: 1, rest: 60),
          _ex('Incline Machine Press', 3, 8, 12, rest: 120),
          _ex('EZ-Bar Curl', 3, 8, 12, rir: 1, rest: 75),
          _ex('Rope Pushdown', 3, 10, 15, rir: 1, rest: 75),
          _ex('Face Pull', 2, 15, 20, rir: 1, rest: 60),
        ],
      ),
      ProgramDay(
        weekday: 6,
        kind: SessionKind.run,
        title: '5K session',
        focus: 'Intervals / tempo toward sub-30',
        minutes: 45,
        run: RunPlan(
          type: 'intervals',
          minutes: 35,
          description: 'Quality session.',
          paceMinS: z.interval.$1,
          paceMaxS: z.interval.$2,
        ),
      ),
      ProgramDay(
        weekday: 7,
        kind: SessionKind.recovery,
        title: 'Weak-point pump',
        focus: 'Active recovery — light delts, lats, arms + posing',
        minutes: 55,
        exercises: [
          _ex('Cable Lateral Raise', 3, 15, 20, rest: 60),
          _ex('Incline Machine Press', 2, 10, 15, rir: 3, rest: 90),
          _ex('Straight-Arm Pulldown', 2, 12, 15, rest: 75),
          _ex('Reverse Pec Deck', 2, 15, 20, rest: 60),
          _ex('Cable Curl', 2, 12, 15, rest: 60),
          _ex('Rope Pushdown', 2, 12, 15, rest: 60),
          _ex(
            'Stomach Vacuum + Posing Practice',
            1,
            10,
            10,
            rir: 0,
            rest: 0,
            note: '10 minutes. Optional 20-min incline walk after.',
          ),
        ],
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Restrictions & readiness
// ---------------------------------------------------------------------------

/// A restriction relevant to training (from `health_restrictions`).
class TrainingRestriction {
  const TrainingRestriction({required this.description, this.bodyPart});
  final String description;
  final String? bodyPart;

  Set<String> get tags => BodyPart.fromText('${bodyPart ?? ''} $description');
}

class ExerciseWarning {
  const ExerciseWarning({
    required this.original,
    required this.substitute,
    required this.restriction,
  });
  final String original;
  final String? substitute;
  final String restriction;
}

/// Swaps exercises that stress a restricted body part for their listed
/// substitute (following the chain until one is safe). Exercises without a
/// safe substitute are kept and flagged.
({ProgramDay day, List<ExerciseWarning> warnings}) applyRestrictions(
  ProgramDay day,
  List<TrainingRestriction> restrictions,
) {
  if (restrictions.isEmpty || day.exercises.isEmpty) {
    return (day: day, warnings: const []);
  }
  final out = <ExercisePlan>[];
  final warnings = <ExerciseWarning>[];
  for (final e in day.exercises) {
    TrainingRestriction? hit(String name) {
      final stress = exerciseLibrary[name]?.stress ?? const <String>{};
      for (final r in restrictions) {
        if (r.tags.intersection(stress).isNotEmpty) return r;
      }
      return null;
    }

    final r = hit(e.name);
    if (r == null) {
      out.add(e);
      continue;
    }
    String? candidate = exerciseLibrary[e.name]?.substitute;
    final seen = {e.name};
    while (candidate != null && hit(candidate) != null) {
      if (!seen.add(candidate)) {
        candidate = null;
        break;
      }
      candidate = exerciseLibrary[candidate]?.substitute;
    }
    warnings.add(
      ExerciseWarning(
        original: e.name,
        substitute: candidate,
        restriction: r.description,
      ),
    );
    out.add(
      candidate == null
          ? e.copyWith(note: 'Caution: ${r.description}')
          : e.copyWith(
              name: candidate,
              note: 'Swapped from ${e.name} (${r.description})',
            ),
    );
  }
  return (day: day.copyWith(exercises: out), warnings: warnings);
}

class Readiness {
  const Readiness({this.energy, this.sleepMinutes});

  /// Today's mood check-in energy (1..5), if logged.
  final int? energy;

  /// Last night's sleep, if known (phone-only: often unknown).
  final int? sleepMinutes;

  bool get suggestLighter =>
      (energy != null && energy! <= 2) ||
      (sleepMinutes != null && sleepMinutes! < 360);

  String? get reason {
    if (!suggestLighter) return null;
    final parts = [
      if (energy != null && energy! <= 2) 'energy $energy/5',
      if (sleepMinutes != null && sleepMinutes! < 360)
        'sleep ${sleepMinutes! ~/ 60} h ${sleepMinutes! % 60} min',
    ];
    return parts.join(' · ');
  }
}

/// Lighter variant: one fewer set per exercise (min 1), +1 RIR; runs become
/// easy and 20 % shorter.
ProgramDay lighterSession(ProgramDay day) {
  final run = day.run;
  return day.copyWith(
    title: '${day.title} · Lighter',
    exercises: [
      for (final e in day.exercises)
        e.copyWith(sets: math.max(1, e.sets - 1), rir: e.rir + 1),
    ],
    run: run == null
        ? null
        : () => RunPlan(
            type: 'easy',
            minutes: (run.minutes * 0.8).round(),
            description: 'Readiness is low: keep it easy and short.',
            paceMinS: run.type == 'easy' ? run.paceMinS : run.paceMaxS + 60,
            paceMaxS: run.type == 'easy' ? run.paceMaxS : run.paceMaxS + 105,
          ),
  );
}
