import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../domain/calibration.dart';
import '../domain/nutrition_calculator.dart';

/// Weekly calorie check-in. Proposes (never applies) a ±100–150 kcal change
/// as a pending `ai_recommendations` row (kind `nutrition`); the user accepts
/// or dismisses it. One proposal per ISO week at most.
class NutritionAdjustmentService {
  NutritionAdjustmentService({
    required this.db,
    required this.profiles,
    required this.settings,
    required this.clock,
  });

  final AppDatabase db;
  final ProfileRepository profiles;
  final SettingsRepository settings;
  final Clock clock;

  static String recIdForWeek(String weekStart) =>
      stableId('persona_nutrition_adjustment', weekStart);

  Future<List<WeightReading>> _readings(String today) async {
    final from = LocalDates.addDays(today, -13);
    final rows =
        await (db.select(db.healthSamples)..where(
              (s) =>
                  s.type.equals('weight') &
                  s.localDate.isBetweenValues(from, today),
            ))
            .get();
    return [
      for (final r in rows)
        WeightReading(
          r.localDate,
          r.unit.toLowerCase() == 'lb' ? r.value * 0.45359237 : r.value,
        ),
    ];
  }

  /// Evaluates the trend and stores a pending recommendation when a change
  /// is warranted. Returns the analysis either way.
  Future<KcalAdjustment> evaluate() async {
    final now = clock.now();
    final today = LocalDates.key(now);
    final answers = CalibrationAnswers.fromJson(
      await settings.get<Object?>(PersonaKeys.calibration),
    );
    final targetRate = switch (answers.goal) {
      NutritionGoal.leanBulk => answers.weeklyRatePct.abs(),
      NutritionGoal.recomp => -0.25,
      _ => -answers.weeklyRatePct.abs(),
    };
    final result = weeklyAdjustment(
      readings: await _readings(today),
      today: today,
      targetRatePct: targetRate,
    );
    if (!result.hasProposal) return result;

    final id = recIdForWeek(LocalDates.weekStart(today));
    final exists = await (db.select(
      db.aiRecommendations,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (exists != null) return result;

    final p = await profiles.get();
    final next = applyKcalDelta(
      kcal: p.calorieTarget,
      proteinG: p.proteinTargetG.round(),
      fatG: p.fatTargetG.round(),
      deltaKcal: result.deltaKcal,
    );
    final sign = result.deltaKcal > 0 ? '+' : '';
    await db
        .into(db.aiRecommendations)
        .insert(
          AiRecommendationsCompanion.insert(
            id: id,
            kind: 'nutrition',
            content:
                'Weekly check-in: ${result.message}\n'
                'Proposed: $sign${result.deltaKcal} kcal/day '
                '(${p.calorieTarget} → ${next.kcal} kcal; carbs '
                '${p.carbsTargetG.round()} → ${next.carbsG} g; protein and '
                'fat unchanged). Estimate — accept only if it matches how '
                'training and hunger feel.',
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await settings.set(PersonaKeys.adjustment(id), {
      'deltaKcal': result.deltaKcal,
      'kcal': next.kcal,
      'carbsG': next.carbsG,
    });
    return result;
  }

  Stream<List<AiRecommendation>> watchPending() =>
      (db.select(db.aiRecommendations)
            ..where(
              (r) => r.kind.equals('nutrition') & r.status.equals('pending'),
            )
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
          .watch();

  /// Applies an accepted proposal through the profile (logged to goal
  /// history as `ai_approved`).
  Future<void> accept(String recId) async {
    final payload = await settings.get<Object?>(PersonaKeys.adjustment(recId));
    if (payload is Map) {
      final kcal = (payload['kcal'] as num?)?.toInt();
      final carbs = (payload['carbsG'] as num?)?.toDouble();
      if (kcal != null && carbs != null) {
        await profiles.update(
          UserProfilesCompanion(
            calorieTarget: Value(kcal),
            carbsTargetG: Value(carbs),
          ),
          changedBy: 'ai_approved',
          reason: 'Weekly nutrition adjustment (accepted)',
        );
      }
    }
    await _respond(recId, 'accepted');
  }

  Future<void> dismiss(String recId) => _respond(recId, 'dismissed');

  Future<void> _respond(String id, String status) =>
      (db.update(db.aiRecommendations)..where((r) => r.id.equals(id))).write(
        AiRecommendationsCompanion(
          status: Value(status),
          respondedAt: Value(clock.now().toUtc()),
        ),
      );
}

final nutritionAdjustmentServiceProvider = Provider<NutritionAdjustmentService>(
  (ref) => NutritionAdjustmentService(
    db: ref.watch(databaseProvider),
    profiles: ref.watch(profileRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    clock: ref.watch(clockProvider),
  ),
);

final pendingNutritionAdjustmentsProvider =
    StreamProvider<List<AiRecommendation>>(
      (ref) => ref.watch(nutritionAdjustmentServiceProvider).watchPending(),
    );
