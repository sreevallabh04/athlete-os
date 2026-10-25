/// Answers collected by the JARVIS calibration wizard. Pure Dart, JSON
/// round-trippable (persisted in AppSettings under [PersonaKeys.calibration]).
library;

import 'nutrition_calculator.dart';

/// Well-being rituals the user can opt into. Each maps to reminder kinds in
/// the life feature (see `CalibrationService`).
enum Ritual {
  moodCheckIn('mood', 'Daily mood check-in', '21:30 prompt'),
  journal('journal', 'Journal + AI reflection', '22:00 prompt'),
  morningBriefing('briefing', 'Morning briefing', '06:15, after waking'),
  eveningReview('review', 'Evening review', '21:45 wrap-up'),
  focusBlocks('focus', 'Focus blocks & top-3 priorities', 'In your routine'),
  water('water', 'Hydration reminders', 'Every 90 min while awake'),
  workout('workout', 'Workout reminder', '06:00 on training days');

  const Ritual(this.key, this.label, this.detail);
  final String key;
  final String label;
  final String detail;

  static Ritual? fromKey(String key) {
    for (final r in values) {
      if (r.key == key) return r;
    }
    return null;
  }
}

/// Habits that can be seeded into the habit tracker.
enum SeedHabit {
  trainProgram('train', 'Complete today\'s session'),
  stepGoal('steps', 'Hit step goal'),
  waterGoal('water', 'Hit water goal'),
  logMeals('meals', 'Log every meal'),
  proteinTarget('protein', 'Reach protein target'),
  sleepOnTime('sleep', 'Lights out on time'),
  posing('posing', 'Posing practice (10 min)');

  const SeedHabit(this.key, this.label);
  final String key;
  final String label;

  static SeedHabit? fromKey(String key) {
    for (final h in values) {
      if (h.key == key) return h;
    }
    return null;
  }
}

class MessagingApp {
  const MessagingApp(this.packageName, this.label);
  final String packageName;
  final String label;
}

const messagingAppChoices = <MessagingApp>[
  MessagingApp('com.whatsapp', 'WhatsApp'),
  MessagingApp('com.google.android.gm', 'Gmail'),
  MessagingApp('com.google.android.apps.messaging', 'Google Messages'),
  MessagingApp('com.instagram.android', 'Instagram'),
  MessagingApp('com.twitter.android', 'X'),
  MessagingApp('org.telegram.messenger', 'Telegram'),
  MessagingApp('com.Slack', 'Slack'),
];

const competitionCategories = <String>[
  'Men\'s Physique',
  'Classic Physique',
  'Bodybuilding',
  'Fitness model',
  'None yet',
];

const dietTypes = <String>[
  'eggetarian',
  'vegetarian',
  'vegan',
  'pescatarian',
  'omnivore',
];

enum Experience {
  beginner('beginner', 'Beginner', 'Less than 1 year of consistent lifting'),
  intermediate('intermediate', 'Intermediate', '1–3 years'),
  advanced('advanced', 'Advanced', '3+ years, plateaus need planning');

  const Experience(this.key, this.label, this.detail);
  final String key;
  final String label;
  final String detail;

  static Experience fromKey(String? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => intermediate);
}

enum WearableStatus {
  phoneOnly('phone_only', 'Phone only', 'Watch is damaged — use the phone'),
  galaxyWatch(
    'galaxy_watch',
    'Galaxy Watch',
    'Working watch via Health '
        'Connect',
  ),
  other('other', 'Other wearable', 'Any device that writes to Health Connect'),
  none('none', 'No wearable', 'Manual entry');

  const WearableStatus(this.key, this.label, this.detail);
  final String key;
  final String label;
  final String detail;

  static WearableStatus fromKey(String? key) =>
      values.firstWhere((w) => w.key == key, orElse: () => phoneOnly);
}

class CalibrationAnswers {
  const CalibrationAnswers({
    required this.name,
    required this.addressAs,
    required this.goal,
    required this.category,
    this.competitionDate,
    required this.dietType,
    required this.restrictions,
    required this.dislikes,
    required this.experience,
    required this.weightKg,
    required this.bodyFatPct,
    required this.weeklyRatePct,
    required this.officeStart,
    required this.officeEnd,
    required this.officeDaysMask,
    required this.wakeMinutes,
    required this.sleepMinutes,
    required this.trainingStart,
    required this.liftDays,
    required this.runDays,
    required this.runGoalDistanceM,
    required this.runGoalTimeS,
    required this.stepGoal,
    required this.waterGoalMl,
    required this.personaName,
    required this.personaTraits,
    required this.voiceEnabled,
    required this.rituals,
    required this.habits,
    required this.messagingApps,
    required this.wearable,
    this.job = JobActivity.desk,
  });

  /// Values from the calibration interview (2026-10-24). Every wizard step
  /// is pre-filled with these so the user can simply tap Next.
  factory CalibrationAnswers.interviewDefaults() => const CalibrationAnswers(
    name: 'Sreevallabh',
    addressAs: 'Sreevallabh',
    goal: NutritionGoal.contestPrep,
    category: 'Men\'s Physique',
    dietType: 'eggetarian',
    restrictions: [],
    dislikes: [],
    experience: Experience.intermediate,
    weightKg: 78,
    bodyFatPct: 19,
    weeklyRatePct: 0.6,
    officeStart: 630,
    officeEnd: 1110,
    officeDaysMask: 0x1F,
    wakeMinutes: 360,
    sleepMinutes: 1350,
    trainingStart: 390,
    liftDays: 5,
    runDays: 2,
    runGoalDistanceM: 5000,
    runGoalTimeS: 1800,
    stepGoal: 12000,
    waterGoalMl: 3500,
    personaName: 'JARVIS',
    personaTraits: ['calm', 'witty', 'formal'],
    voiceEnabled: true,
    rituals: {
      Ritual.moodCheckIn,
      Ritual.journal,
      Ritual.morningBriefing,
      Ritual.eveningReview,
      Ritual.focusBlocks,
      Ritual.water,
      Ritual.workout,
    },
    habits: {
      SeedHabit.trainProgram,
      SeedHabit.stepGoal,
      SeedHabit.waterGoal,
      SeedHabit.logMeals,
      SeedHabit.sleepOnTime,
    },
    messagingApps: [
      'com.whatsapp',
      'com.google.android.gm',
      'com.google.android.apps.messaging',
      'com.instagram.android',
      'com.twitter.android',
    ],
    wearable: WearableStatus.phoneOnly,
  );

  final String name;
  final String addressAs;
  final NutritionGoal goal;
  final String category;

  /// YYYY-MM-DD or null when no date is fixed.
  final String? competitionDate;
  final String dietType;
  final List<String> restrictions;
  final List<String> dislikes;
  final Experience experience;
  final double weightKg;
  final double bodyFatPct;
  final double weeklyRatePct;

  /// Minutes after midnight.
  final int officeStart;
  final int officeEnd;

  /// Bit0 = Monday … bit6 = Sunday.
  final int officeDaysMask;
  final int wakeMinutes;
  final int sleepMinutes;
  final int trainingStart;
  final int liftDays;
  final int runDays;
  final int runGoalDistanceM;
  final int runGoalTimeS;
  final int stepGoal;
  final int waterGoalMl;
  final String personaName;
  final List<String> personaTraits;
  final bool voiceEnabled;
  final Set<Ritual> rituals;
  final Set<SeedHabit> habits;
  final List<String> messagingApps;
  final WearableStatus wearable;
  final JobActivity job;

  bool get hasCompetition =>
      competitionDate != null && category != competitionCategories.last;

  NutritionInputs get nutritionInputs => NutritionInputs(
    weightKg: weightKg,
    bodyFatPct: bodyFatPct,
    liftDaysPerWeek: liftDays,
    runDaysPerWeek: runDays,
    dailySteps: stepGoal,
    job: job,
    goal: goal,
    weeklyRatePct: weeklyRatePct,
  );

  CalibrationAnswers copyWith({
    String? name,
    String? addressAs,
    NutritionGoal? goal,
    String? category,
    String? Function()? competitionDate,
    String? dietType,
    List<String>? restrictions,
    List<String>? dislikes,
    Experience? experience,
    double? weightKg,
    double? bodyFatPct,
    double? weeklyRatePct,
    int? officeStart,
    int? officeEnd,
    int? officeDaysMask,
    int? wakeMinutes,
    int? sleepMinutes,
    int? trainingStart,
    int? liftDays,
    int? runDays,
    int? runGoalDistanceM,
    int? runGoalTimeS,
    int? stepGoal,
    int? waterGoalMl,
    String? personaName,
    List<String>? personaTraits,
    bool? voiceEnabled,
    Set<Ritual>? rituals,
    Set<SeedHabit>? habits,
    List<String>? messagingApps,
    WearableStatus? wearable,
    JobActivity? job,
  }) => CalibrationAnswers(
    name: name ?? this.name,
    addressAs: addressAs ?? this.addressAs,
    goal: goal ?? this.goal,
    category: category ?? this.category,
    competitionDate: competitionDate != null
        ? competitionDate()
        : this.competitionDate,
    dietType: dietType ?? this.dietType,
    restrictions: restrictions ?? this.restrictions,
    dislikes: dislikes ?? this.dislikes,
    experience: experience ?? this.experience,
    weightKg: weightKg ?? this.weightKg,
    bodyFatPct: bodyFatPct ?? this.bodyFatPct,
    weeklyRatePct: weeklyRatePct ?? this.weeklyRatePct,
    officeStart: officeStart ?? this.officeStart,
    officeEnd: officeEnd ?? this.officeEnd,
    officeDaysMask: officeDaysMask ?? this.officeDaysMask,
    wakeMinutes: wakeMinutes ?? this.wakeMinutes,
    sleepMinutes: sleepMinutes ?? this.sleepMinutes,
    trainingStart: trainingStart ?? this.trainingStart,
    liftDays: liftDays ?? this.liftDays,
    runDays: runDays ?? this.runDays,
    runGoalDistanceM: runGoalDistanceM ?? this.runGoalDistanceM,
    runGoalTimeS: runGoalTimeS ?? this.runGoalTimeS,
    stepGoal: stepGoal ?? this.stepGoal,
    waterGoalMl: waterGoalMl ?? this.waterGoalMl,
    personaName: personaName ?? this.personaName,
    personaTraits: personaTraits ?? this.personaTraits,
    voiceEnabled: voiceEnabled ?? this.voiceEnabled,
    rituals: rituals ?? this.rituals,
    habits: habits ?? this.habits,
    messagingApps: messagingApps ?? this.messagingApps,
    wearable: wearable ?? this.wearable,
    job: job ?? this.job,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'addressAs': addressAs,
    'goal': goal.key,
    'category': category,
    'competitionDate': competitionDate,
    'dietType': dietType,
    'restrictions': restrictions,
    'dislikes': dislikes,
    'experience': experience.key,
    'weightKg': weightKg,
    'bodyFatPct': bodyFatPct,
    'weeklyRatePct': weeklyRatePct,
    'officeStart': officeStart,
    'officeEnd': officeEnd,
    'officeDaysMask': officeDaysMask,
    'wakeMinutes': wakeMinutes,
    'sleepMinutes': sleepMinutes,
    'trainingStart': trainingStart,
    'liftDays': liftDays,
    'runDays': runDays,
    'runGoalDistanceM': runGoalDistanceM,
    'runGoalTimeS': runGoalTimeS,
    'stepGoal': stepGoal,
    'waterGoalMl': waterGoalMl,
    'personaName': personaName,
    'personaTraits': personaTraits,
    'voiceEnabled': voiceEnabled,
    'rituals': [for (final r in rituals) r.key],
    'habits': [for (final h in habits) h.key],
    'messagingApps': messagingApps,
    'wearable': wearable.key,
    'job': job.key,
  };

  /// Lenient parse: missing/invalid fields fall back to the interview
  /// defaults.
  static CalibrationAnswers fromJson(Object? json) {
    final d = CalibrationAnswers.interviewDefaults();
    if (json is! Map) return d;
    T pick<T>(String k, T fallback) {
      final v = json[k];
      return v is T ? v : fallback;
    }

    double dbl(String k, double fallback) {
      final v = json[k];
      return v is num ? v.toDouble() : fallback;
    }

    int integer(String k, int fallback) {
      final v = json[k];
      return v is num ? v.toInt() : fallback;
    }

    List<String> strings(String k, List<String> fallback) {
      final v = json[k];
      return v is List ? [for (final e in v) '$e'] : fallback;
    }

    return CalibrationAnswers(
      name: pick('name', d.name),
      addressAs: pick('addressAs', d.addressAs),
      goal: NutritionGoal.fromKey(json['goal'] as String?),
      category: pick('category', d.category),
      competitionDate: json['competitionDate'] as String?,
      dietType: pick('dietType', d.dietType),
      restrictions: strings('restrictions', d.restrictions),
      dislikes: strings('dislikes', d.dislikes),
      experience: Experience.fromKey(json['experience'] as String?),
      weightKg: dbl('weightKg', d.weightKg),
      bodyFatPct: dbl('bodyFatPct', d.bodyFatPct),
      weeklyRatePct: dbl('weeklyRatePct', d.weeklyRatePct),
      officeStart: integer('officeStart', d.officeStart),
      officeEnd: integer('officeEnd', d.officeEnd),
      officeDaysMask: integer('officeDaysMask', d.officeDaysMask),
      wakeMinutes: integer('wakeMinutes', d.wakeMinutes),
      sleepMinutes: integer('sleepMinutes', d.sleepMinutes),
      trainingStart: integer('trainingStart', d.trainingStart),
      liftDays: integer('liftDays', d.liftDays),
      runDays: integer('runDays', d.runDays),
      runGoalDistanceM: integer('runGoalDistanceM', d.runGoalDistanceM),
      runGoalTimeS: integer('runGoalTimeS', d.runGoalTimeS),
      stepGoal: integer('stepGoal', d.stepGoal),
      waterGoalMl: integer('waterGoalMl', d.waterGoalMl),
      personaName: pick('personaName', d.personaName),
      personaTraits: strings('personaTraits', d.personaTraits),
      voiceEnabled: pick('voiceEnabled', d.voiceEnabled),
      rituals: json['rituals'] is List
          ? {for (final k in json['rituals'] as List) ?Ritual.fromKey('$k')}
          : d.rituals,
      habits: json['habits'] is List
          ? {for (final k in json['habits'] as List) ?SeedHabit.fromKey('$k')}
          : d.habits,
      messagingApps: strings('messagingApps', d.messagingApps),
      wearable: WearableStatus.fromKey(json['wearable'] as String?),
      job: JobActivity.fromKey(json['job'] as String?),
    );
  }
}

/// AppSettings keys owned by the onboarding/persona feature.
abstract final class PersonaKeys {
  static const calibration = 'persona.calibration';
  static const nutritionPlan = 'persona.nutrition_plan';
  static const messagingApps = 'persona.messaging_apps';
  static const program = 'program.active';
  static String adjustment(String recId) => 'persona.adjustment.$recId';
}

String hhmm(int minutes) {
  final m = minutes % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}
