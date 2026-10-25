import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import 'nutrition_tools.dart' show loadProfile;
import 'tool_args_validator.dart';
import 'tool_spec.dart';
import 'tool_support.dart';

/// Cardio sources the AI may see. Strava is excluded everywhere by policy.
const aiAllowedCardioSources = ['health_connect', 'manual'];

/// Health samples written by the Strava app are treated as Strava data too.
Expression<bool> notFromStrava(HealthSamples s) =>
    s.sourceApp.isNull() | s.sourceApp.lower().like('%strava%').not();

/// Cardio rows the AI may see: soft-deleted rows, Strava rows and Strava-
/// derived rows are excluded. The Strava Android app also writes its
/// activities to Health Connect, and the HC sync imports those sessions as
/// `source = 'health_connect'` (the writing app is kept in `rawJson.source_app`
/// and in the generated name, e.g. "Run · Strava"), so the source column alone
/// is not enough.
Expression<bool> aiVisibleCardio(CardioActivities c) =>
    c.deletedAt.isNull() &
    c.source.isIn(aiAllowedCardioSources) &
    (c.rawJson.isNull() | c.rawJson.lower().like('%strava%').not()) &
    (c.name.isNull() | c.name.lower().like('%strava%').not());

/// Steps per day: Health Connect aggregate preferred, manual otherwise.
Future<Map<String, DailyHealthSummary>> stepsByDay(
  AppDatabase db,
  DateRange range,
) async {
  final rows =
      await (db.select(db.dailyHealthSummaries)..where(
            (d) =>
                d.type.equals('steps') &
                d.localDate.isBetweenValues(range.start, range.end),
          ))
          .get();
  final out = <String, DailyHealthSummary>{};
  for (final r in rows) {
    final cur = out[r.localDate];
    if (cur == null ||
        (cur.origin != 'health_connect' && r.origin == 'health_connect')) {
      out[r.localDate] = r;
    }
  }
  return out;
}

final getStepsSummaryTool = ToolSpec(
  name: 'get_steps_summary',
  description:
      'Daily steps for a day or range (max 31 days) with the step goal, '
      'steps remaining today, source and sync freshness.',
  inputSchema: S.object(dateRangeProps()),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read steps · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today);
    final goal = (await loadProfile(ctx.db))?.stepGoal ?? 10000;
    final byDay = await stepsByDay(ctx.db, range);
    final missing = <String>[];
    final days = <String, Object?>{};
    DateTime? latest;
    for (final d in range.days) {
      final r = byDay[d];
      if (r == null) {
        missing.add('no step data for $d');
        continue;
      }
      if (latest == null || r.computedAt.isAfter(latest)) latest = r.computedAt;
      days[d] = {
        'steps': r.value.round(),
        'remaining_to_goal': math.max(0, goal - r.value.round()),
        'source': sourceLabel(r.origin),
        'devices': ?r.sourcesSummary,
      };
    }
    final todayRow = byDay[ctx.today];
    final stale =
        todayRow != null &&
        ctx.now.difference(todayRow.computedAt.toLocal()) >
            const Duration(hours: 3);
    return {
      'goal_steps': goal,
      'days': days,
      if (range.days.contains(ctx.today))
        'today': {
          'steps': todayRow?.value.round(),
          'remaining_to_goal': todayRow == null
              ? null
              : math.max(0, goal - todayRow.value.round()),
          'last_synced': ?todayRow?.computedAt.toUtc().toIso8601String(),
          'stale': stale,
        },
      'missing': missing,
      'provenance': provenance(
        sources: byDay.values.map((r) => sourceLabel(r.origin)),
        asOf: latest,
        range: range,
        note: stale ? 'Today\'s steps were last synced over 3 h ago.' : null,
      ),
    };
  },
);

Future<List<Map<String, Object?>>> _workoutDetails(
  AppDatabase db,
  List<Workout> workouts,
) async {
  final out = <Map<String, Object?>>[];
  for (final w in workouts) {
    final exercises =
        await (db.select(db.workoutExercises)
              ..where((e) => e.workoutId.equals(w.id))
              ..orderBy([(e) => OrderingTerm.asc(e.position)]))
            .get();
    final exJson = <Map<String, Object?>>[];
    var totalVolume = 0.0;
    for (final e in exercises.take(15)) {
      final sets = await (db.select(
        db.workoutSets,
      )..where((s) => s.exerciseId.equals(e.id))).get();
      final working = sets.where((s) => s.setType != 'warmup').toList();
      var volume = 0.0;
      WorkoutSet? top;
      for (final s in working) {
        volume += (s.weightKg ?? 0) * (s.reps ?? 0);
        if (s.weightKg != null &&
            (top == null || s.weightKg! > (top.weightKg ?? 0))) {
          top = s;
        }
      }
      totalVolume += volume;
      exJson.add({
        'name': e.name,
        'working_sets': working.length,
        'top_set': ?top == null
            ? null
            : '${r1(top.weightKg!)} kg × ${top.reps ?? '?'}',
        'volume_kg': r1(volume),
      });
    }
    out.add({
      'id': w.id,
      'date': w.localDate,
      'title': w.title,
      'source': sourceLabel(w.source),
      'duration_min': ?w.endAt?.difference(w.startAt).inMinutes,
      'exercises': exJson,
      'total_volume_kg': r1(totalVolume),
    });
  }
  return out;
}

final getWorkoutHistoryTool = ToolSpec(
  name: 'get_workout_history',
  description:
      'Strength workouts (Hevy/manual) in a date range (default last 30 '
      'days, max 90), newest first, with exercises, working sets, top sets '
      'and volume.',
  inputSchema: S.object({
    'start_date': S.date('Range start YYYY-MM-DD.'),
    'end_date': S.date('Range end YYYY-MM-DD (default today).'),
    'limit': S.integer('Max workouts (default 5).', minimum: 1, maximum: 20),
  }),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read workouts · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today, defaultDays: 30, maxDays: 90);
    final limit = (args['limit'] as num?)?.toInt() ?? 5;
    final workouts =
        await (ctx.db.select(ctx.db.workouts)
              ..where(
                (w) =>
                    w.deletedAt.isNull() &
                    w.localDate.isBetweenValues(range.start, range.end),
              )
              ..orderBy([(w) => OrderingTerm.desc(w.startAt)])
              ..limit(limit))
            .get();
    return {
      'workouts': await _workoutDetails(ctx.db, workouts),
      'missing': [if (workouts.isEmpty) 'no workouts in range'],
      'provenance': provenance(
        sources: workouts.map((w) => sourceLabel(w.source)),
        asOf: workouts.isEmpty ? null : workouts.first.updatedAt,
        range: range,
      ),
    };
  },
);

/// Epley estimated one-rep max.
double estimatedOneRepMax(double weightKg, int reps) =>
    reps <= 1 ? weightKg : weightKg * (1 + reps / 30);

final getStrengthProgressTool = ToolSpec(
  name: 'get_strength_progress',
  description:
      'Progress for one exercise (name match, case-insensitive) across recent '
      'sessions: best set, estimated 1RM (Epley) and volume per session.',
  inputSchema: S.object(
    {
      'exercise': S.str(
        'Exercise name, e.g. "bench press".',
        minLength: 2,
        maxLength: 80,
      ),
      'limit': S.integer('Max sessions (default 8).', minimum: 1, maximum: 20),
    },
    required: ['exercise'],
  ),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read strength · ${a['exercise'] ?? ''}',
  handler: (ctx, args) async {
    final name = (args['exercise'] as String).trim().toLowerCase();
    final limit = (args['limit'] as num?)?.toInt() ?? 8;
    final pattern = '%${name.replaceAll('%', '').replaceAll('_', '')}%';
    final query =
        ctx.db.select(ctx.db.workoutExercises).join([
            innerJoin(
              ctx.db.workouts,
              ctx.db.workouts.id.equalsExp(ctx.db.workoutExercises.workoutId),
            ),
          ])
          ..where(
            ctx.db.workoutExercises.name.lower().like(pattern) &
                ctx.db.workouts.deletedAt.isNull(),
          )
          ..orderBy([OrderingTerm.desc(ctx.db.workouts.startAt)])
          ..limit(limit);
    final rows = await query.get();
    final sessions = <Map<String, Object?>>[];
    for (final row in rows) {
      final ex = row.readTable(ctx.db.workoutExercises);
      final w = row.readTable(ctx.db.workouts);
      final sets =
          await (ctx.db.select(ctx.db.workoutSets)..where(
                (s) =>
                    s.exerciseId.equals(ex.id) & s.setType.isNotValue('warmup'),
              ))
              .get();
      double best1rm = 0;
      String? bestSet;
      var volume = 0.0;
      for (final s in sets) {
        if (s.weightKg == null || s.reps == null) continue;
        volume += s.weightKg! * s.reps!;
        final e1 = estimatedOneRepMax(s.weightKg!, s.reps!);
        if (e1 > best1rm) {
          best1rm = e1;
          bestSet = '${r1(s.weightKg!)} kg × ${s.reps}';
        }
      }
      sessions.add({
        'date': w.localDate,
        'exercise': ex.name,
        'sets': sets.length,
        'best_set': ?bestSet,
        'estimated_1rm_kg': best1rm == 0 ? null : r1(best1rm),
        'volume_kg': r1(volume),
      });
    }
    final e1s = sessions
        .map((s) => s['estimated_1rm_kg'] as double?)
        .whereType<double>()
        .toList();
    return {
      'exercise_query': name,
      'sessions': sessions,
      if (e1s.length >= 2) 'change_estimated_1rm_kg': r1(e1s.first - e1s.last),
      'missing': [if (sessions.isEmpty) 'no sessions found for "$name"'],
      'provenance': provenance(
        sources: rows.map(
          (r) => sourceLabel(r.readTable(ctx.db.workouts).source),
        ),
        range: sessions.isEmpty
            ? null
            : DateRange(
                sessions.last['date'] as String,
                sessions.first['date'] as String,
              ),
        note: 'Estimated 1RM uses the Epley formula; it is an estimate.',
      ),
    };
  },
);

final getRunningActivitiesTool = ToolSpec(
  name: 'get_running_activities',
  description:
      'Runs and other cardio recorded via Health Connect or entered manually '
      '(default last 30 days, max 90). Strava activities are never included '
      '(Strava policy).',
  inputSchema: S.object({
    'start_date': S.date('Range start YYYY-MM-DD.'),
    'end_date': S.date('Range end YYYY-MM-DD (default today).'),
    'sport_type': S.str(
      'Filter (default run).',
      enumValues: ['run', 'walk', 'ride', 'hike', 'other', 'any'],
    ),
    'limit': S.integer('Max activities (default 10).', minimum: 1, maximum: 30),
  }),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read runs · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today, defaultDays: 30, maxDays: 90);
    final sport = args['sport_type'] as String? ?? 'run';
    final limit = (args['limit'] as num?)?.toInt() ?? 10;
    final rows =
        await (ctx.db.select(ctx.db.cardioActivities)
              ..where(
                (c) =>
                    aiVisibleCardio(c) &
                    c.localDate.isBetweenValues(range.start, range.end) &
                    (sport == 'any'
                        ? const Constant(true)
                        : c.sportType.equals(sport)),
              )
              ..orderBy([(c) => OrderingTerm.desc(c.startAt)])
              ..limit(limit))
            .get();
    final totalM = rows.fold<double>(0, (a, c) => a + (c.distanceM ?? 0));
    return {
      'activities': [
        for (final c in rows)
          {
            'id': c.id,
            'date': c.localDate,
            'sport': c.sportType,
            'name': ?c.name,
            'distance_km': ?c.distanceM == null
                ? null
                : r2(c.distanceM! / 1000),
            'moving_time_s': ?c.movingTimeS,
            'pace_s_per_km':
                c.distanceM != null && c.distanceM! > 0 && c.movingTimeS != null
                ? (c.movingTimeS! / (c.distanceM! / 1000)).round()
                : null,
            'avg_hr': ?c.avgHeartRate?.round(),
            'source': sourceLabel(c.source),
          },
      ],
      'total_distance_km': r2(totalM / 1000),
      'missing': [if (rows.isEmpty) 'no non-Strava $sport activities in range'],
      'policy_note':
          'Strava activities are excluded by Strava API policy; the user can '
          'analyse them on-device in the Running screen.',
      'provenance': provenance(
        sources: rows.map((c) => sourceLabel(c.source)),
        asOf: rows.isEmpty ? null : rows.first.updatedAt,
        range: range,
      ),
    };
  },
);

final getStravaActivitiesTool = ToolSpec(
  name: 'get_strava_activities',
  description:
      'Strava activities are NOT available to AI (Strava policy). Returns a '
      'notice explaining where the user can analyse them on-device.',
  inputSchema: S.object({}),
  chipLabel: (a, now) => 'Strava · unavailable to AI',
  handler: (ctx, args) async => Map<String, Object?>.of(stravaPolicyNotice),
);

final analyzeStravaActivityTool = ToolSpec(
  name: 'analyze_strava_activity',
  description:
      'Strava activity analysis is NOT available to AI (Strava policy). '
      'Returns a notice pointing to the on-device rule-based analysis.',
  inputSchema: S.object({'activity_id': S.str('Ignored.', maxLength: 64)}),
  chipLabel: (a, now) => 'Strava · unavailable to AI',
  handler: (ctx, args) async => Map<String, Object?>.of(stravaPolicyNotice),
);

/// Latest value of a health sample type (excluding Strava-written samples).
Future<HealthSample?> latestSample(AppDatabase db, String type) =>
    (db.select(db.healthSamples)
          ..where((s) => s.type.equals(type) & notFromStrava(s))
          ..orderBy([(s) => OrderingTerm.desc(s.startAt)])
          ..limit(1))
        .getSingleOrNull();

Future<DailyHealthSummary?> summaryFor(
  AppDatabase db,
  String type,
  String date,
) async {
  final rows = await (db.select(
    db.dailyHealthSummaries,
  )..where((d) => d.type.equals(type) & d.localDate.equals(date))).get();
  if (rows.isEmpty) return null;
  return rows.firstWhere(
    (r) => r.origin == 'health_connect',
    orElse: () => rows.first,
  );
}

/// The local date before [today] (e.g. for "last night" sleep).
String yesterdayOf(String today) => LocalDates.addDays(today, -1);
