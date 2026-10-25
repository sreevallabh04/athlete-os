import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../assistant/application/providers.dart'
    show briefingServiceProvider;
import '../../assistant/domain/briefing_builder.dart' show BriefingInputs;
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/training_program.dart';
import '../../planning/application/planning_providers.dart';
import 'widgets/quick_commands.dart';

/// Live readouts for the Coach's hero and quick commands. Every field is
/// nullable: unknown is shown as unknown, never as zero.
class CoachTelemetry {
  const CoachTelemetry({
    required this.now,
    this.name,
    this.inputs,
    this.session,
    this.daysToCompetition,
    this.competitionName,
  });

  final DateTime now;
  final String? name;
  final BriefingInputs? inputs;
  final PlannedSession? session;
  final int? daysToCompetition;
  final String? competitionName;

  int? get steps => inputs?.steps;
  int? get stepGoal => inputs?.stepGoal;
  double? get proteinLeft {
    final t = inputs?.proteinTarget, c = inputs?.proteinConsumed;
    return t == null || c == null ? null : t - c;
  }

  int? get waterLeftMl {
    final g = inputs?.waterGoalMl, w = inputs?.waterMl;
    return g == null || w == null ? null : g - w;
  }

  int get pendingDrafts => inputs?.pendingDrafts ?? 0;

  QuickContext get quick => QuickContext(
    now: now,
    hasNutritionTarget: (inputs?.proteinTarget ?? 0) > 0,
    hasCompetition: daysToCompetition != null && daysToCompetition! >= 0,
    hasSessionToday:
        session != null && session!.day.kind != SessionKind.recovery,
    pendingDrafts: pendingDrafts,
    stepsBelowGoal:
        steps != null &&
        stepGoal != null &&
        stepGoal! > 0 &&
        steps! < stepGoal!,
    waterBelowGoal: (waterLeftMl ?? 0) > 0,
  );
}

Future<T?> _safe<T>(Future<T?> Function() f) async {
  try {
    return await f();
  } catch (_) {
    return null;
  }
}

final coachTelemetryProvider = FutureProvider.autoDispose<CoachTelemetry>((
  ref,
) async {
  final now = ref.watch(clockProvider).now();
  final today = LocalDates.key(now);
  final inputs = await _safe(() => ref.read(briefingServiceProvider).gather());
  final profile = await _safe(() => ref.read(profileRepositoryProvider).get());
  final session = await _safe(
    () => ref.watch(plannedSessionProvider(today).future),
  );
  final comp = await _safe(() => ref.watch(competitionViewProvider.future));
  return CoachTelemetry(
    now: now,
    name: profile?.displayName,
    inputs: inputs,
    session: session,
    daysToCompetition: comp?.countdown.daysRemaining,
    competitionName: comp?.competition.name,
  );
});
