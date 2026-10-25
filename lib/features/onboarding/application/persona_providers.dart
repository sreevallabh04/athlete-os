import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/time/clock.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../life/data/watch_tables.dart';
import '../data/calibration_service.dart';
import '../domain/calibration.dart';
import '../domain/daily_routine.dart';
import '../domain/meal_ideas.dart';
import '../domain/training_program.dart';

// ---------------------------------------------------------------------------
// First-launch gate
// ---------------------------------------------------------------------------

/// Whether onboarding is done: `null` = not loaded (no redirect), loaded by
/// the onboarding bootstrap hook before the first frame.
class OnboardingGate extends Notifier<bool?> {
  @override
  bool? build() => null;

  Future<void> load() async {
    try {
      state = await ref.read(personaRepositoryProvider).onboardingDone();
    } catch (_) {
      state = null;
    }
  }

  void markDone() => state = true;
}

final onboardingGateProvider = NotifierProvider<OnboardingGate, bool?>(
  OnboardingGate.new,
);

/// Pure redirect rule (unit-tested).
String? onboardingRedirectFor({required bool? done, required String path}) {
  if (done != false) return null;
  if (path == AppPaths.onboarding) return null;
  return AppPaths.onboarding;
}

/// GoRouter top-level redirect: first launch → `/onboarding`.
String? onboardingRedirect(BuildContext context, GoRouterState state) {
  bool? done;
  try {
    done = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(onboardingGateProvider);
  } catch (_) {
    return null;
  }
  return onboardingRedirectFor(done: done, path: state.uri.path);
}

// ---------------------------------------------------------------------------
// Calibration & program
// ---------------------------------------------------------------------------

final calibrationProvider = StreamProvider<CalibrationAnswers?>(
  (ref) => ref.watch(personaRepositoryProvider).watchCalibration(),
);

final activeProgramProvider = StreamProvider<TrainingProgram?>(
  (ref) => ref.watch(personaRepositoryProvider).watchProgram(),
);

/// Today's (or any date's) session with deload, restrictions and readiness
/// applied.
class PlannedSession {
  const PlannedSession({
    required this.date,
    required this.week,
    required this.isDeload,
    required this.day,
    required this.warnings,
    required this.readiness,
    required this.program,
  });

  final String date;
  final int week;
  final bool isDeload;

  /// Session after deload + restriction substitution.
  final ProgramDay day;
  final List<ExerciseWarning> warnings;
  final Readiness readiness;
  final TrainingProgram program;

  /// Lighter alternative when readiness is low (null otherwise).
  ProgramDay? get lighter =>
      readiness.suggestLighter ? lighterSession(day) : null;

  String get heroTag => 'planned-session-$date';
}

List<TrainingRestriction> activeRestrictions(
  List<({String description, String? bodyPart, String? start, String? end})>
  rows,
  String date,
) => [
  for (final r in rows)
    if ((r.start == null || r.start!.compareTo(date) <= 0) &&
        (r.end == null || r.end!.compareTo(date) >= 0))
      TrainingRestriction(description: r.description, bodyPart: r.bodyPart),
];

PlannedSession planSession({
  required TrainingProgram program,
  required String date,
  List<TrainingRestriction> restrictions = const [],
  Readiness readiness = const Readiness(),
}) {
  final base = program.sessionFor(date);
  final r = applyRestrictions(base, restrictions);
  final week = program.weekNumber(date);
  return PlannedSession(
    date: date,
    week: week,
    isDeload: program.isDeloadWeek(week),
    day: r.day,
    warnings: r.warnings,
    readiness: readiness,
    program: program,
  );
}

/// Planned sessions for any date; reloads on program/restriction/mood/sleep
/// changes.
final plannedSessionProvider = StreamProvider.family<PlannedSession?, String>((
  ref,
  date,
) {
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(personaRepositoryProvider);
  return watchTables(
    db,
    [
      db.appSettings,
      db.healthRestrictions,
      db.moodEntries,
      db.dailyHealthSummaries,
    ],
    () async {
      final program = await repo.program();
      if (program == null) return null;
      final rows = await db.select(db.healthRestrictions).get();
      final mood =
          await (db.select(db.moodEntries)
                ..where((m) => m.localDate.equals(date) & m.deletedAt.isNull())
                ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)])
                ..limit(1))
              .getSingleOrNull();
      final sleep =
          await (db.select(db.dailyHealthSummaries)
                ..where(
                  (s) =>
                      s.localDate.equals(date) & s.type.equals('sleep_minutes'),
                )
                ..limit(1))
              .getSingleOrNull();
      return planSession(
        program: program,
        date: date,
        restrictions: activeRestrictions([
          for (final r in rows)
            (
              description: r.description,
              bodyPart: r.bodyPart,
              start: r.startDate,
              end: r.endDate,
            ),
        ], date),
        readiness: Readiness(
          energy: mood?.energy,
          sleepMinutes: sleep?.value.round(),
        ),
      );
    },
  );
});

/// Today's planned session (null until JARVIS calibration has run).
final todaysPlannedSessionProvider = Provider<AsyncValue<PlannedSession?>>((
  ref,
) {
  final today = LocalDates.key(ref.watch(clockProvider).now());
  return ref.watch(plannedSessionProvider(today));
});

// ---------------------------------------------------------------------------
// Routine
// ---------------------------------------------------------------------------

List<RoutineBlock> routineFor({
  required CalibrationAnswers a,
  required String date,
  required int proteinTargetG,
  PlannedSession? session,
}) {
  final weekday = LocalDates.parse(date).weekday;
  final meals = mealsForDiet(a.dietType, dislikes: a.dislikes);
  return buildRoutine(
    RoutineInput(
      weekday: weekday,
      wake: a.wakeMinutes,
      sleep: a.sleepMinutes,
      trainingStart: a.trainingStart,
      trainingMinutes: session?.day.minutes ?? 70,
      sessionTitle: session == null
          ? 'Training'
          : '${session.day.title} · ${session.day.focus}',
      officeStart: a.officeStart,
      officeEnd: a.officeEnd,
      isOfficeDay: a.officeDaysMask & (1 << (weekday - 1)) != 0,
      proteinTargetG: proteinTargetG,
      stepGoal: a.stepGoal,
      focusBlocks: a.rituals.contains(Ritual.focusBlocks),
      rituals: a.rituals,
      mealExamples: [
        for (final slot in ['breakfast', 'lunch', 'snack', 'dinner'])
          ?meals.where((m) => m.slot == slot).firstOrNull?.name,
      ],
    ),
  );
}

/// Today's timeline (null until calibration has run).
final todaysRoutineProvider = Provider<AsyncValue<List<RoutineBlock>?>>((ref) {
  final today = LocalDates.key(ref.watch(clockProvider).now());
  final cal = ref.watch(calibrationProvider);
  final session = ref.watch(plannedSessionProvider(today));
  final profile = ref.watch(profileProvider);
  if (cal.isLoading || profile.isLoading) return const AsyncLoading();
  final a = cal.value;
  if (a == null) return const AsyncData(null);
  return AsyncData(
    routineFor(
      a: a,
      date: today,
      proteinTargetG: profile.value?.proteinTargetG.round() ?? 170,
      session: session.value,
    ),
  );
});
