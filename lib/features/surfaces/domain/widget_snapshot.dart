/// The data the "JARVIS Today" home-screen widget renders, built from the
/// same sources as the Today dashboard. Pure Dart (unit-tested).
///
/// Honesty rules: a value is non-null only when something was actually
/// logged or synced today. A day with no water logs is `waterMl == null`
/// (rendered "—"), never 0; steps are null until Health Connect / a source
/// has delivered a value for today. Targets always come from the profile.
library;

import 'dart:convert';

import '../../../core/time/clock.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/daily_routine.dart';
import '../../today/data/today_repository.dart';

/// Wire format version shared with `surfaces/WidgetSnapshot.kt`.
const widgetSnapshotVersion = 1;

class WidgetMetric {
  const WidgetMetric({required this.value, required this.target});

  /// Real logged/synced value for today, or null when there is none.
  final double? value;

  /// Profile target (> 0) or null when unset.
  final double? target;

  /// 0..1 progress, or null when the value or target is missing.
  double? get progress {
    final v = value;
    final t = target;
    if (v == null || t == null || t <= 0) return null;
    return (v / t).clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() => {'v': value, 't': target};

  @override
  bool operator ==(Object other) =>
      other is WidgetMetric && other.value == value && other.target == target;

  @override
  int get hashCode => Object.hash(value, target);
}

class WidgetRoutineBlock {
  const WidgetRoutineBlock({
    required this.start,
    required this.end,
    required this.title,
    required this.kind,
  });

  /// Minutes after local midnight.
  final int start;
  final int end;
  final String title;
  final String kind;

  Map<String, Object?> toJson() => {
    's': start,
    'e': end,
    't': title,
    'k': kind,
  };
}

class WidgetSnapshot {
  const WidgetSnapshot({
    required this.date,
    required this.updatedAt,
    required this.steps,
    required this.protein,
    required this.calories,
    required this.water,
    this.sessionTitle,
    this.sessionKind,
    this.sessionDone = false,
    this.routine = const [],
  });

  /// Local date (YYYY-MM-DD) the values belong to. The native renderer shows
  /// "—" for every value when this is not today's date.
  final String date;
  final DateTime updatedAt;
  final WidgetMetric steps;
  final WidgetMetric protein;
  final WidgetMetric calories;
  final WidgetMetric water;

  /// e.g. "Upper A · Push" (null until a program exists or on rest days).
  final String? sessionTitle;

  /// lift | run | recovery.
  final String? sessionKind;

  /// A workout was logged today.
  final bool sessionDone;

  /// Today's routine blocks, sorted by start; the native side picks the next
  /// one at render time so the widget stays right without the app running.
  final List<WidgetRoutineBlock> routine;

  /// The block that starts next at [minuteOfDay] (or null).
  WidgetRoutineBlock? nextBlock(int minuteOfDay) {
    for (final b in routine) {
      if (b.start >= minuteOfDay) return b;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'ver': widgetSnapshotVersion,
    'date': date,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'steps': steps.toJson(),
    'protein': protein.toJson(),
    'calories': calories.toJson(),
    'water': water.toJson(),
    'session': sessionTitle == null
        ? null
        : {'title': sessionTitle, 'kind': sessionKind, 'done': sessionDone},
    'routine': [for (final b in routine) b.toJson()],
  };

  String encode() => jsonEncode(toJson());

  /// Encoding without the timestamp — two snapshots with the same content
  /// key need only one widget update.
  String contentKey() {
    final m = toJson()..remove('updatedAt');
    return jsonEncode(m);
  }
}

double? _positive(num? n) => (n == null || n <= 0) ? null : n.toDouble();

/// Builds the snapshot. Every argument may be null while its source loads
/// (or when it never existed); the matching fields then stay null.
WidgetSnapshot buildWidgetSnapshot({
  required DateTime now,
  TodaySnapshot? today,
  PlannedSession? session,
  List<RoutineBlock>? routine,
}) {
  final date = LocalDates.key(now);
  // A snapshot computed for another day must not leak into today.
  final t = today != null && today.date == date ? today : null;
  final profile = today?.profile;
  final nutritionLogged = t?.nutrition.logged ?? false;

  final s = session != null && session.date == date ? session : null;
  String? sessionTitle;
  if (s != null) {
    final day = s.day;
    final parts = [
      day.title.trim(),
      if (day.focus.trim().isNotEmpty && day.focus.trim() != day.title.trim())
        day.focus.trim(),
    ];
    sessionTitle = parts.where((p) => p.isNotEmpty).join(' · ');
    if (s.isDeload) sessionTitle = '$sessionTitle · Deload';
    if (sessionTitle.isEmpty) sessionTitle = null;
  }

  final blocks = [...?routine]..sort((a, b) => a.start.compareTo(b.start));

  return WidgetSnapshot(
    date: date,
    updatedAt: now,
    steps: WidgetMetric(
      value: t?.steps?.value,
      target: _positive(profile?.stepGoal),
    ),
    protein: WidgetMetric(
      value: nutritionLogged ? t!.nutrition.proteinG : null,
      target: _positive(profile?.proteinTargetG),
    ),
    calories: WidgetMetric(
      value: nutritionLogged ? t!.nutrition.kcal : null,
      target: _positive(profile?.calorieTarget),
    ),
    water: WidgetMetric(
      value: t?.waterLastLoggedAt != null ? t!.waterMl.toDouble() : null,
      target: _positive(profile?.waterGoalMl),
    ),
    sessionTitle: sessionTitle,
    sessionKind: s?.day.kind.key,
    sessionDone: s != null && t?.workoutToday != null,
    routine: [
      for (final b in blocks.take(32))
        WidgetRoutineBlock(
          start: b.start,
          end: b.end,
          title: b.title,
          kind: b.kind.name,
        ),
    ],
  );
}
