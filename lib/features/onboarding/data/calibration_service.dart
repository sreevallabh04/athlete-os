import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../health/application/health_providers.dart';
import '../../health/data/health_repository.dart';
import '../../life/data/habit_repository.dart';
import '../../life/data/notification_prefs_repository.dart';
import '../../life/domain/auto_rules.dart';
import '../../life/domain/habit_models.dart';
import '../../life/domain/reminder_kinds.dart';
import '../../planning/data/planning_repository.dart';
import '../domain/calibration.dart';
import '../domain/nutrition_calculator.dart';
import '../domain/training_program.dart';

/// Reads persona/program state from AppSettings.
class PersonaRepository {
  PersonaRepository(this._settings);
  final SettingsRepository _settings;

  Future<CalibrationAnswers?> calibration() async {
    final v = await _settings.get<Object?>(PersonaKeys.calibration);
    return v == null ? null : CalibrationAnswers.fromJson(v);
  }

  Stream<CalibrationAnswers?> watchCalibration() => _settings
      .watch<Object?>(PersonaKeys.calibration)
      .map((v) => v == null ? null : CalibrationAnswers.fromJson(v));

  Stream<TrainingProgram?> watchProgram() => _settings
      .watch<Object?>(PersonaKeys.program)
      .map(TrainingProgram.fromJson);

  Future<TrainingProgram?> program() async => TrainingProgram.fromJson(
    await _settings.get<Object?>(PersonaKeys.program),
  );

  Future<bool> onboardingDone() async =>
      (await _settings.get<Object?>(SettingKeys.onboardingDone)) == true;
}

final personaRepositoryProvider = Provider<PersonaRepository>(
  (ref) => PersonaRepository(ref.watch(settingsRepositoryProvider)),
);

/// Reminder kinds JARVIS calibration manages, with the interview times.
const ritualReminderTimes = <Ritual, (ReminderKind, int)>{
  Ritual.moodCheckIn: (ReminderKind.mood, 21 * 60 + 30),
  Ritual.journal: (ReminderKind.journal, 22 * 60),
  Ritual.morningBriefing: (ReminderKind.planning, 6 * 60 + 15),
  Ritual.eveningReview: (ReminderKind.eodReview, 21 * 60 + 45),
};

class EngageResult {
  const EngageResult({
    required this.plan,
    required this.program,
    required this.habitsCreated,
    required this.remindersEnabled,
    this.competitionId,
  });
  final NutritionPlan plan;
  final TrainingProgram program;
  final List<String> habitsCreated;
  final List<ReminderKind> remindersEnabled;
  final String? competitionId;
}

/// Applies calibration answers. Nothing is written before [engage] is called
/// (the wizard keeps answers in memory until the user taps Engage).
class CalibrationService {
  CalibrationService({
    required this.profiles,
    required this.settings,
    required this.habits,
    required this.prefs,
    required this.planning,
    required this.health,
    required this.clock,
    required this.db,
  });

  final ProfileRepository profiles;
  final SettingsRepository settings;
  final HabitRepository habits;
  final NotificationPrefsRepository prefs;
  final PlanningRepository planning;
  final HealthRepository health;
  final Clock clock;
  final AppDatabase db;

  Future<EngageResult> engage(
    CalibrationAnswers a, {
    String tzName = 'Asia/Kolkata',
  }) async {
    final now = clock.now();
    final today = LocalDates.key(now);
    final plan = calculateNutrition(a.nutritionInputs);
    final stageMid = double.parse(
      ((plan.stageWeightLowKg + plan.stageWeightHighKg) / 2).toStringAsFixed(1),
    );

    // 1. Profile + goal history (one row per changed field).
    await profiles.update(
      UserProfilesCompanion(
        displayName: Value(a.name.trim()),
        targetWeightKg: Value(a.goal.isDeficit ? stageMid : a.weightKg),
        dietType: Value(a.dietType),
        restrictionsJson: Value(jsonEncode(a.restrictions)),
        dislikedFoodsJson: Value(jsonEncode(a.dislikes)),
        calorieTarget: Value(plan.targetKcal),
        proteinTargetG: Value(plan.proteinG.toDouble()),
        carbsTargetG: Value(plan.carbsG.toDouble()),
        fatTargetG: Value(plan.fatG.toDouble()),
        fiberTargetG: Value(plan.fiberG.toDouble()),
        stepGoal: Value(a.stepGoal),
        waterGoalMl: Value(a.waterGoalMl),
        wakeMinutes: Value(a.wakeMinutes),
        sleepMinutes: Value(a.sleepMinutes),
        coachingStyle: const Value('analytical'),
        trainingAvailability: Value(
          'Early morning from ${hhmm(a.trainingStart)}, 7 days '
          '(${a.liftDays} lift + ${a.runDays} run). Office '
          '${hhmm(a.officeStart)}–${hhmm(a.officeEnd)} '
          '${describeDaysMask(a.officeDaysMask)}.',
        ),
        runGoalDistanceM: Value(a.runGoalDistanceM),
        runGoalTimeS: Value(a.runGoalTimeS),
        fitnessGoals: Value(
          '${a.goal.label}'
          '${a.category == competitionCategories.last ? '' : ' · ${a.category}'}'
          ' · ${a.runGoalDistanceM ~/ 1000}K under '
          '${a.runGoalTimeS ~/ 60}:${(a.runGoalTimeS % 60).toString().padLeft(2, '0')}',
        ),
      ),
      changedBy: 'user',
      reason: 'JARVIS calibration',
    );

    // 2. Program (week 1 = this week's Monday).
    final program = generateMensPhysiqueProgram(
      startMonday: LocalDates.weekStart(today),
      runGoalDistanceM: a.runGoalDistanceM,
      runGoalTimeS: a.runGoalTimeS,
    );

    // 3. Settings JSON.
    await settings.set(PersonaKeys.calibration, a.toJson());
    await settings.set(PersonaKeys.nutritionPlan, plan.toJson());
    await settings.set(PersonaKeys.program, program.toJson());
    await settings.set(PersonaKeys.messagingApps, [
      for (final p in a.messagingApps)
        {
          'package': p,
          'label': messagingAppChoices
              .where((m) => m.packageName == p)
              .map((m) => m.label)
              .firstOrNull,
        },
    ]);

    // 4. Habits (only those selected; never duplicates by name).
    final existing = {
      for (final h in await habits.habits(includeArchived: true))
        h.name.trim().toLowerCase(),
    };
    final created = <String>[];
    for (final h in SeedHabit.values) {
      if (!a.habits.contains(h)) continue;
      final input = _habitInput(h, a);
      if (existing.contains(input.name.toLowerCase())) continue;
      await habits.create(input);
      created.add(input.name);
    }

    // 5. Reminders: only chosen kinds are enabled; managed kinds that were
    // not chosen are switched off so a recalibration reflects the answers.
    final enabled = <ReminderKind>[];
    final current = await prefs.all();
    Future<void> setKind(
      ReminderKind kind,
      bool on,
      ReminderConfig config,
    ) async {
      if (on) {
        await prefs.save(kind, enabled: true, config: config);
        enabled.add(kind);
      } else if (current[kind]?.enabled ?? false) {
        await prefs.save(kind, enabled: false);
      }
    }

    for (final e in ritualReminderTimes.entries) {
      final (kind, minute) = e.value;
      await setKind(
        kind,
        a.rituals.contains(e.key),
        kind.defaults.copyWith(times: [minute], daysMask: allDaysMask),
      );
    }
    final wakeSpan = ((a.sleepMinutes - a.wakeMinutes) % 1440 + 1440) % 1440;
    await setKind(
      ReminderKind.water,
      a.rituals.contains(Ritual.water),
      ReminderKind.water.defaults.copyWith(
        intervalMinutes: 90,
        maxPerDay: (wakeSpan ~/ 90).clamp(1, 24),
      ),
    );
    await setKind(
      ReminderKind.workout,
      a.rituals.contains(Ritual.workout),
      ReminderKind.workout.defaults.copyWith(
        times: [a.trainingStart - 30],
        daysMask: _trainingDaysMask(program),
      ),
    );

    // 6. Competition (only when a date was given).
    String? compId;
    if (a.hasCompetition) {
      final existingComp = await planning.primaryCompetition();
      compId = await planning.saveCompetition(
        id: existingComp?.id,
        name: existingComp?.name ?? a.category,
        eventDate: a.competitionDate!,
        tzName: existingComp?.tzName ?? tzName,
        location: existingComp?.location,
        division: a.category,
        notes: existingComp?.notes,
      );
    }

    // 7. Today's weigh-in, if none recorded yet.
    final weighedToday = await (db.select(
      db.healthSamples,
    )..where((s) => s.type.equals('weight') & s.localDate.equals(today))).get();
    if (weighedToday.isEmpty && a.weightKg >= 20 && a.weightKg <= 400) {
      await health.addManualWeight(a.weightKg, note: 'JARVIS calibration');
    }

    await settings.set(SettingKeys.onboardingDone, true);
    return EngageResult(
      plan: plan,
      program: program,
      habitsCreated: created,
      remindersEnabled: enabled,
      competitionId: compId,
    );
  }

  static int _trainingDaysMask(TrainingProgram p) {
    var mask = 0;
    for (final d in p.days) {
      mask |= weekdayBit(d.weekday);
    }
    return mask;
  }

  static HabitInput _habitInput(SeedHabit h, CalibrationAnswers a) =>
      switch (h) {
        SeedHabit.trainProgram => const HabitInput(
          name: 'Complete today\'s session',
          category: HabitCategory.fitness,
          notes: 'From your JARVIS program (lift or run).',
        ),
        SeedHabit.stepGoal => const HabitInput(
          name: 'Hit step goal',
          category: HabitCategory.fitness,
          autoRule: AutoRule.stepGoal,
        ),
        SeedHabit.waterGoal => const HabitInput(
          name: 'Hit water goal',
          category: HabitCategory.health,
          autoRule: AutoRule.waterGoal,
        ),
        SeedHabit.logMeals => const HabitInput(
          name: 'Log every meal',
          category: HabitCategory.nutrition,
          autoRule: AutoRule.foodLogged,
        ),
        SeedHabit.proteinTarget => const HabitInput(
          name: 'Reach protein target',
          category: HabitCategory.nutrition,
        ),
        SeedHabit.sleepOnTime => HabitInput(
          name: 'Lights out by ${hhmm(a.sleepMinutes)}',
          category: HabitCategory.health,
        ),
        SeedHabit.posing => const HabitInput(
          name: 'Posing practice (10 min)',
          category: HabitCategory.fitness,
          schedule: HabitSchedule.weekly(3),
        ),
      };
}

final calibrationServiceProvider = Provider<CalibrationService>(
  (ref) => CalibrationService(
    profiles: ref.watch(profileRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    habits: ref.watch(habitRepositoryProvider),
    prefs: ref.watch(notificationPrefsRepositoryProvider),
    planning: ref.watch(planningRepositoryProvider),
    health: ref.watch(healthRepositoryProvider),
    clock: ref.watch(clockProvider),
    db: ref.watch(databaseProvider),
  ),
);
