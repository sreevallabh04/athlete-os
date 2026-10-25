import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/domain/free_slots.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import 'activity_tools.dart';
import 'nutrition_tools.dart';
import 'tool_args_validator.dart';
import 'tool_spec.dart';
import 'tool_support.dart';

// ---------------------------------------------------------------------------
// Calendar & scheduling
// ---------------------------------------------------------------------------

String _hhmm(DateTime t) => DateFormat('HH:mm').format(t);

final getCalendarEventsTool = ToolSpec(
  name: 'get_calendar_events',
  description:
      'Calendar events between two dates (max 14 days, default today). '
      'Reports honestly when no calendar is connected.',
  inputSchema: S.object({
    'start_date': S.date('Start YYYY-MM-DD (default today).'),
    'end_date': S.date('End YYYY-MM-DD inclusive (default start_date).'),
  }),
  chipLabel: (a, now) => 'Read calendar · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final start = args['start_date'] as String? ?? ctx.today;
    final end = args['end_date'] as String? ?? start;
    final range = resolveRange(
      {'start_date': start, 'end_date': end},
      ctx.today,
      maxDays: 14,
    );
    final from = LocalDates.bounds(range.start).$1;
    final to = LocalDates.bounds(range.end).$2;
    final res = await ctx.calendar.eventsBetween(from, to);
    if (!res.connected) {
      return {
        'connected': false,
        'events': const <Object>[],
        'missing': ['no calendar connected (Integrations → Google Calendar)'],
        'provenance': provenance(sources: const [], range: range),
      };
    }
    if (res.error != null) {
      return {
        'connected': true,
        'error': 'calendar_unavailable',
        'missing': ['calendar could not be read right now'],
        'provenance': provenance(sources: ['Google Calendar'], range: range),
      };
    }
    final events = [...res.events]..sort((a, b) => a.start.compareTo(b.start));
    return {
      'connected': true,
      'events': [
        for (final e in events.take(60))
          {
            'title': e.title,
            'date': LocalDates.key(e.start),
            'start': e.allDay ? null : _hhmm(e.start.toLocal()),
            'end': e.allDay ? null : _hhmm(e.end.toLocal()),
            'all_day': e.allDay,
            'busy': e.isBusy,
          },
      ],
      'provenance': provenance(
        sources: ['Google Calendar'],
        asOf: res.fetchedAt,
        range: range,
      ),
    };
  },
);

DateTime _at(String date, int minutes) {
  final d = LocalDates.parse(date);
  return DateTime(d.year, d.month, d.day, 0, minutes);
}

int _parseHhmm(String s) =>
    int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5));

final suggestScheduleTool = ToolSpec(
  name: 'suggest_schedule',
  description:
      'Finds candidate time slots on a day that fit a duration, avoiding '
      'calendar events (with a buffer) and staying inside the wake/sleep '
      'window. Read-only: it never creates events.',
  inputSchema: S.object(
    {
      'date': S.date('Day YYYY-MM-DD (default today).'),
      'duration_min': S.integer(
        'Slot length in minutes.',
        minimum: 10,
        maximum: 240,
      ),
      'earliest': S.str(
        'Earliest start HH:MM (default wake time).',
        format: 'time',
      ),
      'latest': S.str('Latest end HH:MM (default sleep time).', format: 'time'),
      'buffer_min': S.integer(
        'Gap around events (default 10).',
        minimum: 0,
        maximum: 60,
      ),
      'max_slots': S.integer(
        'Max suggestions (default 3).',
        minimum: 1,
        maximum: 5,
      ),
    },
    required: ['duration_min'],
  ),
  chipLabel: (a, now) =>
      'Checked free time · ${a['date'] is String ? shortDate(a['date'] as String) : shortDate(LocalDates.key(now))}',
  handler: (ctx, args) async {
    final date = args['date'] as String? ?? ctx.today;
    if (date.compareTo(ctx.today) < 0) {
      throw ArgumentError('Cannot schedule in the past ($date).');
    }
    final duration = Duration(minutes: (args['duration_min'] as num).toInt());
    final buffer = Duration(
      minutes: (args['buffer_min'] as num?)?.toInt() ?? 10,
    );
    final maxSlots = (args['max_slots'] as num?)?.toInt() ?? 3;
    final profile = await loadProfile(ctx.db);
    final wake = args['earliest'] is String
        ? _parseHhmm(args['earliest'] as String)
        : profile?.wakeMinutes ?? 390;
    final sleep = args['latest'] is String
        ? _parseHhmm(args['latest'] as String)
        : profile?.sleepMinutes ?? 1350;
    var start = _at(date, wake);
    final end = _at(date, sleep);
    if (date == ctx.today) {
      final now = ctx.now;
      final rounded = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute + (5 - now.minute % 5) % 5,
      );
      if (rounded.isAfter(start)) start = rounded;
    }
    final (dayStart, dayEnd) = LocalDates.bounds(date);
    final cal = await ctx.calendar.eventsBetween(dayStart, dayEnd);
    final busy = [
      for (final e in cal.events)
        if (e.isBusy && !e.allDay)
          TimeInterval(e.start.toLocal(), e.end.toLocal()),
    ];
    final slots = !start.isBefore(end)
        ? const <TimeInterval>[]
        : findFreeSlots(
            window: TimeInterval(start, end),
            busy: busy,
            minDuration: duration,
            buffer: buffer,
          );
    final calendarChecked = cal.connected && cal.error == null;
    return {
      'date': date,
      'duration_min': duration.inMinutes,
      'window': {'start': _hhmm(start), 'end': _hhmm(end)},
      'calendar_checked': calendarChecked,
      'busy_blocks': busy.length,
      'candidate_slots': [
        for (final s in slots.take(maxSlots))
          {
            'start': _hhmm(s.start),
            'end': _hhmm(s.start.add(duration)),
            'free_until': _hhmm(s.end),
          },
      ],
      'missing': [
        if (!cal.connected)
          'calendar not connected — slots only respect the wake/sleep window',
        if (cal.connected && cal.error != null)
          'calendar could not be read — slots may conflict with events',
        if (slots.isEmpty) 'no free slot of that length in the window',
      ],
      'provenance': provenance(
        sources: [
          'Profile wake/sleep window',
          if (calendarChecked) 'Google Calendar',
        ],
        asOf: cal.fetchedAt,
        range: DateRange(date, date),
        note: 'Suggestions only; nothing was added to the calendar.',
      ),
    };
  },
);

// ---------------------------------------------------------------------------
// Habits, mood, journal
// ---------------------------------------------------------------------------

bool habitDueOn(Habit h, String date) {
  if (h.scheduleType == 'weekly') return false;
  if (h.scheduleType == 'custom') {
    final wd = LocalDates.parse(date).weekday; // Mon = 1
    return h.daysMask & (1 << (wd - 1)) != 0;
  }
  return true;
}

final getHabitSummaryTool = ToolSpec(
  name: 'get_habit_summary',
  description:
      'Habit completion for a day or range (default last 7 days, max 31): '
      'per-habit done/due counts, completion rate and current streak.',
  inputSchema: S.object(dateRangeProps()),
  chipLabel: (a, now) => 'Read habits · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today, defaultDays: 7);
    final habits =
        await (ctx.db.select(ctx.db.habits)
              ..where((h) => h.deletedAt.isNull() & h.archived.equals(false))
              ..orderBy([(h) => OrderingTerm.asc(h.sortOrder)]))
            .get();
    final streakStart = LocalDates.addDays(ctx.today, -90);
    final completions =
        await (ctx.db.select(ctx.db.habitCompletions)..where(
              (c) =>
                  c.localDate.isBetweenValues(
                    streakStart.compareTo(range.start) < 0
                        ? streakStart
                        : range.start,
                    range.end,
                  ) &
                  c.status.equals('done'),
            ))
            .get();
    final doneBy = <String, Set<String>>{};
    for (final c in completions) {
      doneBy.putIfAbsent(c.habitId, () => {}).add(c.localDate);
    }
    final out = <Map<String, Object?>>[];
    var totalDue = 0, totalDone = 0;
    for (final h in habits.take(30)) {
      final done = doneBy[h.id] ?? const <String>{};
      final inRange = range.days.where(done.contains).length;
      int due;
      if (h.scheduleType == 'weekly') {
        due = ((h.targetPerWeek ?? 1) * range.length / 7).ceil();
      } else {
        due = range.days.where((d) => habitDueOn(h, d)).length;
      }
      var streak = 0;
      if (h.scheduleType != 'weekly') {
        var d = done.contains(ctx.today) ? ctx.today : yesterdayOf(ctx.today);
        while (d.compareTo(streakStart) >= 0) {
          if (!habitDueOn(h, d)) {
            d = LocalDates.addDays(d, -1);
            continue;
          }
          if (!done.contains(d)) break;
          streak++;
          d = LocalDates.addDays(d, -1);
        }
      }
      totalDue += due;
      totalDone += inRange.clamp(0, due);
      out.add({
        'name': h.name,
        'category': h.category,
        'schedule': h.scheduleType,
        'done': inRange,
        'due': due,
        'done_today': done.contains(ctx.today),
        'streak_days': streak,
      });
    }
    return {
      'habits': out,
      'completion_rate': totalDue == 0 ? null : r2(totalDone / totalDue),
      'missing': [if (habits.isEmpty) 'no habits set up'],
      'provenance': provenance(sources: ['Habit tracker'], range: range),
    };
  },
);

final logMoodTool = ToolSpec(
  name: 'log_mood',
  description:
      'Records a mood check-in (1–5 scales) for now. Requires user approval.',
  inputSchema: S.object(
    {
      'mood': S.integer(
        'Mood 1 (very low) – 5 (great).',
        minimum: 1,
        maximum: 5,
      ),
      'energy': S.integer('Energy 1–5.', minimum: 1, maximum: 5),
      'stress': S.integer('Stress 1–5.', minimum: 1, maximum: 5),
      'tags': S.array(
        'Emotion tags.',
        S.str('Tag.', minLength: 1, maxLength: 30),
        maxItems: 8,
      ),
      'note': S.str('Short note in the user\'s words.', maxLength: 280),
    },
    required: ['mood'],
  ),
  isWrite: true,
  consent: ToolConsent.health,
  confirmTitle: 'Log mood',
  confirmSummary: (a) => [
    'Mood ${a['mood']}/5'
        '${a['energy'] != null ? ' · energy ${a['energy']}/5' : ''}'
        '${a['stress'] != null ? ' · stress ${a['stress']}/5' : ''}',
    if (a['tags'] is List && (a['tags'] as List).isNotEmpty)
      (a['tags'] as List).join(', '),
    if (a['note'] != null) '"${a['note']}"',
  ],
  chipLabel: (a, now) => 'Logged mood · ${a['mood']}/5',
  handler: (ctx, args) async {
    final id = stableId('ai_tool_mood', ctx.idempotencyKey);
    await ctx.db
        .into(ctx.db.moodEntries)
        .insert(
          MoodEntriesCompanion.insert(
            id: id,
            localDate: ctx.today,
            recordedAt: ctx.now.toUtc(),
            mood: (args['mood'] as num).toInt(),
            energy: Value((args['energy'] as num?)?.toInt()),
            stress: Value((args['stress'] as num?)?.toInt()),
            emotionTagsJson: Value(jsonEncode(args['tags'] ?? const [])),
            note: Value(args['note'] as String?),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return {
      'status': 'logged',
      'id': id,
      'date': ctx.today,
      'provenance': provenance(sources: ['Mood log'], asOf: ctx.now),
    };
  },
);

final getJournalSummaryTool = ToolSpec(
  name: 'get_journal_summary',
  description:
      'Journal overview for a range (default last 7 days, max 31): entry '
      'count, dates and short excerpts (first 200 characters, max 10). Only '
      'available if the user allowed journal sharing.',
  inputSchema: S.object({
    'start_date': S.date('Range start YYYY-MM-DD.'),
    'end_date': S.date('Range end YYYY-MM-DD (default today).'),
  }),
  consent: ToolConsent.journal,
  chipLabel: (a, now) => 'Read journal · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today, defaultDays: 7);
    final rows =
        await (ctx.db.select(ctx.db.journalEntries)
              ..where(
                (j) =>
                    j.deletedAt.isNull() &
                    j.localDate.isBetweenValues(range.start, range.end),
              )
              ..orderBy([(j) => OrderingTerm.desc(j.localDate)]))
            .get();
    String excerpt(String s) {
      final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return t.length <= 200 ? t : '${t.substring(0, 200)}…';
    }

    return {
      'entry_count': rows.length,
      'dates': rows.map((r) => r.localDate).toSet().toList(),
      'excerpts': [
        for (final r in rows.take(10))
          if (r.body.trim().isNotEmpty)
            {'date': r.localDate, 'excerpt': excerpt(r.body)},
      ],
      'missing': [if (rows.isEmpty) 'no journal entries in range'],
      'provenance': provenance(
        sources: ['Journal'],
        range: range,
        note: 'Excerpts only; full entries stay on the device.',
      ),
    };
  },
);

// ---------------------------------------------------------------------------
// Competition, profile, memory
// ---------------------------------------------------------------------------

/// Loads the IANA database only if nobody has yet. `initializeTimeZones()`
/// also resets `tz.local` to UTC, so calling it again after the life
/// bootstrap set the device zone would shift every zoned reminder scheduled
/// afterwards by the UTC offset.
void _ensureTimeZones() {
  if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
}

/// Calendar days from "today in [tzName]" to [eventDate] (YYYY-MM-DD in the
/// event's timezone). Falls back to the device date if the tz is unknown.
({int days, String todayInEventTz, bool tzKnown}) daysUntilEvent(
  String eventDate,
  String tzName,
  DateTime now,
) {
  _ensureTimeZones();
  String today;
  var known = true;
  try {
    final loc = tz.getLocation(tzName);
    final t = tz.TZDateTime.from(now, loc);
    today =
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  } catch (_) {
    known = false;
    today = LocalDates.key(now);
  }
  DateTime utcDay(String k) {
    final p = k.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  return (
    days: utcDay(eventDate).difference(utcDay(today)).inDays,
    todayInEventTz: today,
    tzKnown: known,
  );
}

final getCompetitionCountdownTool = ToolSpec(
  name: 'get_competition_countdown',
  description:
      'Upcoming competitions with calendar days remaining, counted in each '
      "event's own timezone, plus open milestones.",
  inputSchema: S.object({}),
  chipLabel: (a, now) => 'Read competitions',
  handler: (ctx, args) async {
    final comps =
        await (ctx.db.select(ctx.db.competitions)
              ..where((c) => c.deletedAt.isNull())
              ..orderBy([
                (c) => OrderingTerm.desc(c.isPrimary),
                (c) => OrderingTerm.asc(c.eventDate),
              ]))
            .get();
    final out = <Map<String, Object?>>[];
    for (final c in comps) {
      final r = daysUntilEvent(c.eventDate, c.tzName, ctx.now);
      if (r.days < -1) continue; // long past
      final milestones =
          await (ctx.db.select(ctx.db.competitionMilestones)
                ..where(
                  (m) => m.competitionId.equals(c.id) & m.done.equals(false),
                )
                ..orderBy([(m) => OrderingTerm.asc(m.dueDate)])
                ..limit(5))
              .get();
      out.add({
        'name': c.name,
        'event_date': c.eventDate,
        'timezone': c.tzName,
        'days_until': r.days,
        'weeks_until': r1(r.days / 7),
        'today_in_event_tz': r.todayInEventTz,
        'is_primary': c.isPrimary,
        'division': ?c.division,
        'location': ?c.location,
        'open_milestones': [
          for (final m in milestones) {'title': m.title, 'due': ?m.dueDate},
        ],
        if (!r.tzKnown) 'note': 'Unknown timezone; device date used.',
      });
    }
    return {
      'competitions': out,
      'missing': [if (out.isEmpty) 'no upcoming competition saved'],
      'provenance': provenance(
        sources: ['Competition planner'],
        asOf: ctx.now,
        note: 'Days are calendar days in the event timezone (0 = event day).',
      ),
    };
  },
);

List<String> _jsonList(String json) {
  try {
    return (jsonDecode(json) as List).map((e) => e.toString()).toList();
  } catch (_) {
    return const [];
  }
}

Future<List<HealthRestriction>> activeRestrictions(
  AppDatabase db,
  String today,
) async {
  final rows = await db.select(db.healthRestrictions).get();
  return rows
      .where(
        (r) =>
            (r.startDate == null || r.startDate!.compareTo(today) <= 0) &&
            (r.endDate == null || r.endDate!.compareTo(today) >= 0),
      )
      .toList();
}

final getProfileAndGoalsTool = ToolSpec(
  name: 'get_profile_and_goals',
  description:
      'Profile targets (calories, macros, steps, water), diet type, dietary '
      'restrictions, disliked foods, active injuries/restrictions, run goal, '
      'coaching style and schedule window.',
  inputSchema: S.object({}),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read profile & goals',
  handler: (ctx, args) async {
    final p = await loadProfile(ctx.db);
    if (p == null) {
      return {
        'missing': ['profile not set up'],
        'provenance': provenance(sources: const []),
      };
    }
    final restrictions = await activeRestrictions(ctx.db, ctx.today);
    final weight = await latestSample(ctx.db, 'weight');
    String hm(int m) =>
        '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
    return {
      'name': ?p.displayName,
      'targets': {
        ...targetsJson(p),
        'steps': p.stepGoal,
        'water_ml': p.waterGoalMl,
        'target_weight_kg': ?p.targetWeightKg,
      },
      'latest_weight_kg': ?weight == null ? null : r1(weight.value),
      'latest_weight_date': ?weight?.localDate,
      'diet_type': p.dietType,
      'dietary_restrictions': _jsonList(p.restrictionsJson),
      'disliked_foods': _jsonList(p.dislikedFoodsJson),
      'health_restrictions': [
        for (final r in restrictions)
          {
            'description': r.description,
            'body_part': ?r.bodyPart,
            'restriction': ?r.restriction,
            'clinician_imposed': r.clinicianImposed,
            'until': ?r.endDate,
          },
      ],
      'run_goal': {
        'distance_m': p.runGoalDistanceM,
        'target_time_s': p.runGoalTimeS,
      },
      'fitness_goals': ?p.fitnessGoals,
      'training_availability': ?p.trainingAvailability,
      'coaching_style': p.coachingStyle,
      'day_window': {'wake': hm(p.wakeMinutes), 'sleep': hm(p.sleepMinutes)},
      'provenance': provenance(
        sources: ['Profile'],
        asOf: p.updatedAt,
        note: 'Targets change only when the user edits them.',
      ),
    };
  },
);

final recordRecommendationTool = ToolSpec(
  name: 'record_recommendation',
  description:
      'Saves a concrete recommendation you just gave (one sentence) to the '
      "user's AI history so they can accept, edit or dismiss it later. It "
      'does not change any data or targets.',
  inputSchema: S.object(
    {
      'kind': S.str(
        'Area.',
        enumValues: ['habit', 'nutrition', 'training', 'schedule', 'general'],
      ),
      'content': S.str('The recommendation.', minLength: 3, maxLength: 300),
    },
    required: ['kind', 'content'],
  ),
  chipLabel: (a, now) => 'Saved recommendation',
  handler: (ctx, args) async {
    await ctx.db
        .into(ctx.db.aiRecommendations)
        .insert(
          AiRecommendationsCompanion.insert(
            id: stableId('ai_tool_rec', ctx.idempotencyKey),
            kind: args['kind'] as String,
            content: (args['content'] as String).trim(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return {
      'status': 'saved_pending_user_response',
      'provenance': provenance(sources: ['AI history']),
    };
  },
);

final rememberPreferenceTool = ToolSpec(
  name: 'remember_preference',
  description:
      'Proposes a long-term memory (e.g. "prefers morning workouts"). It is '
      'saved as pending and used only after the user approves it in Coach '
      'memory. Never store sensitive health details the user did not ask '
      'you to remember.',
  inputSchema: S.object(
    {
      'category': S.str(
        'Kind of memory.',
        enumValues: ['preference', 'goal', 'routine', 'context'],
      ),
      'content': S.str('One short sentence.', minLength: 3, maxLength: 300),
    },
    required: ['category', 'content'],
  ),
  chipLabel: (a, now) => 'Suggested a memory',
  handler: (ctx, args) async {
    final content = (args['content'] as String).trim();
    final existing =
        await (ctx.db.select(ctx.db.aiMemories)
              ..where((m) => m.content.lower().equals(content.toLowerCase())))
            .getSingleOrNull();
    if (existing != null) {
      return {
        'status': existing.approved ? 'already_remembered' : 'already_pending',
        'provenance': provenance(sources: ['Coach memory']),
      };
    }
    await ctx.db
        .into(ctx.db.aiMemories)
        .insert(
          AiMemoriesCompanion.insert(
            id: stableId('ai_tool_memory', ctx.idempotencyKey),
            category: args['category'] as String,
            content: content,
            origin: const Value('ai_suggested'),
            approved: const Value(false),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return {
      'status': 'pending_user_approval',
      'message':
          'Saved as a suggestion. The user can approve it in Coach memory; '
          'until then it is not used.',
      'provenance': provenance(sources: ['Coach memory']),
    };
  },
);

// ---------------------------------------------------------------------------
// Aggregates
// ---------------------------------------------------------------------------

final getTodayDashboardTool = ToolSpec(
  name: 'get_today_dashboard',
  description:
      'Snapshot of today: food totals vs targets and remaining, water, steps, '
      'workouts/runs logged, habits, mood check-in, last night\'s sleep, '
      'latest weight and next competition countdown.',
  inputSchema: S.object({}),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read today · ${shortDate(LocalDates.key(now))}',
  handler: (ctx, args) async {
    final today = ctx.today;
    final range = DateRange(today, today);
    final profile = await loadProfile(ctx.db);
    final food = totalsByDay(await foodEntries(ctx.db, range), range)[today]!;
    final water = (await ctx.water.totalsByDay(today, today))[today] ?? 0;
    final steps = (await stepsByDay(ctx.db, range))[today];
    final workouts = await (ctx.db.select(
      ctx.db.workouts,
    )..where((w) => w.deletedAt.isNull() & w.localDate.equals(today))).get();
    final runs = await (ctx.db.select(
      ctx.db.cardioActivities,
    )..where((c) => aiVisibleCardio(c) & c.localDate.equals(today))).get();
    final mood =
        await (ctx.db.select(ctx.db.moodEntries)
              ..where((m) => m.deletedAt.isNull() & m.localDate.equals(today))
              ..orderBy([(m) => OrderingTerm.desc(m.recordedAt)])
              ..limit(1))
            .getSingleOrNull();
    final sleep =
        await summaryFor(ctx.db, 'sleep_minutes', today) ??
        await summaryFor(ctx.db, 'sleep_minutes', yesterdayOf(today));
    final weight = await latestSample(ctx.db, 'weight');
    final habits = await getHabitSummaryTool.handler(ctx, {'date': today});
    final comps = await getCompetitionCountdownTool.handler(ctx, const {});
    final nextComp = (comps['competitions'] as List).firstOrNull;
    final stepGoal = profile?.stepGoal ?? 10000;
    final waterGoal = profile?.waterGoalMl ?? 3000;
    final missing = <String>[
      if (food.entries == 0) 'no food logged today',
      if (steps == null) 'no step data synced today',
      if (water == 0) 'no water logged today',
      if (mood == null) 'no mood check-in today',
      if (sleep == null) 'no sleep data for last night',
    ];
    return {
      'date': today,
      'nutrition': {
        'totals': food.toJson(),
        'targets': ?profile == null ? null : targetsJson(profile),
        'remaining': ?profile == null ? null : remainingJson(profile, food),
      },
      'water': {
        'total_ml': water,
        'goal_ml': waterGoal,
        'remaining_ml': waterGoal - water,
      },
      'steps': {
        'steps': steps?.value.round(),
        'goal': stepGoal,
        'remaining_to_goal': steps == null
            ? null
            : (stepGoal - steps.value.round()).clamp(0, stepGoal),
        'source': ?steps == null ? null : sourceLabel(steps.origin),
        'last_synced': ?steps?.computedAt.toUtc().toIso8601String(),
      },
      'training': {
        'workouts': [for (final w in workouts) w.title],
        'cardio': [
          for (final c in runs)
            {
              'sport': c.sportType,
              'distance_km': ?c.distanceM == null
                  ? null
                  : r2(c.distanceM! / 1000),
            },
        ],
      },
      'habits': {
        'done_today': (habits['habits'] as List)
            .where((h) => (h as Map)['done_today'] == true)
            .length,
        'total': (habits['habits'] as List).length,
      },
      'mood_today': ?mood == null
          ? null
          : {'mood': mood.mood, 'energy': mood.energy},
      'sleep_last_night_min': ?sleep?.value.round(),
      'latest_weight': ?weight == null
          ? null
          : {'kg': r1(weight.value), 'date': weight.localDate},
      'next_competition': ?nextComp,
      'missing': missing,
      'provenance': provenance(
        sources: [
          if (food.entries > 0) 'Food log',
          if (water > 0) 'Water log',
          if (steps != null) sourceLabel(steps.origin),
          if (workouts.isNotEmpty) 'Workouts',
          if (mood != null) 'Mood log',
          'Profile',
        ],
        asOf: ctx.now,
        range: range,
        note: 'Strava activities are excluded by policy.',
      ),
    };
  },
);

final getWeeklyReportTool = ToolSpec(
  name: 'get_weekly_report',
  description:
      'Monday–Sunday summary for a week (default this week): nutrition '
      'averages and adherence, water, steps, workouts, runs, habit '
      'completion and mood average.',
  inputSchema: S.object({
    'week_start': S.date('Any date in the week, YYYY-MM-DD (default today).'),
  }),
  consent: ToolConsent.health,
  chipLabel: (a, now) {
    final d = a['week_start'] is String
        ? a['week_start'] as String
        : LocalDates.key(now);
    final ws = ToolArgsValidator.isValidDate(d) ? LocalDates.weekStart(d) : d;
    return 'Read week · ${ToolArgsValidator.isValidDate(ws) ? shortDate(ws) : ws}';
  },
  handler: (ctx, args) async {
    final anchor = args['week_start'] as String? ?? ctx.today;
    final start = LocalDates.weekStart(anchor);
    final fullEnd = LocalDates.addDays(start, 6);
    final end = fullEnd.compareTo(ctx.today) > 0 ? ctx.today : fullEnd;
    if (start.compareTo(ctx.today) > 0) {
      throw ArgumentError('That week has not started yet.');
    }
    final range = DateRange(start, end);
    final profile = await loadProfile(ctx.db);
    final food = totalsByDay(await foodEntries(ctx.db, range), range);
    final logged = food.values.where((d) => d.entries > 0).toList();
    double avg(Iterable<double> v) =>
        v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    final adherent = profile == null
        ? null
        : logged
              .where(
                (d) =>
                    (d.calories - profile.calorieTarget).abs() <=
                    profile.calorieTarget * 0.1,
              )
              .length;
    final proteinHit = profile == null
        ? null
        : logged.where((d) => d.protein >= profile.proteinTargetG * 0.9).length;
    final water = await ctx.water.totalsByDay(start, end);
    final steps = await stepsByDay(ctx.db, range);
    final workouts =
        await (ctx.db.select(ctx.db.workouts)..where(
              (w) =>
                  w.deletedAt.isNull() &
                  w.localDate.isBetweenValues(start, end),
            ))
            .get();
    final runs =
        await (ctx.db.select(ctx.db.cardioActivities)..where(
              (c) =>
                  aiVisibleCardio(c) & c.localDate.isBetweenValues(start, end),
            ))
            .get();
    final moods =
        await (ctx.db.select(ctx.db.moodEntries)..where(
              (m) =>
                  m.deletedAt.isNull() &
                  m.localDate.isBetweenValues(start, end),
            ))
            .get();
    final habits = await getHabitSummaryTool.handler(ctx, {
      'start_date': start,
      'end_date': end,
    });
    return {
      'week': {'start': start, 'end': fullEnd, 'through': end},
      'nutrition': {
        'days_logged': logged.length,
        'avg_calories_kcal': r1(avg(logged.map((d) => d.calories))),
        'avg_protein_g': r1(avg(logged.map((d) => d.protein))),
        'days_within_10pct_of_calorie_target': ?adherent,
        'days_protein_at_least_90pct': ?proteinHit,
        'estimated_entries': logged.fold<int>(
          0,
          (a, d) => a + d.estimatedEntries,
        ),
      },
      'water_avg_ml': water.isEmpty
          ? 0
          : (water.values.reduce((a, b) => a + b) / water.length).round(),
      'steps': {
        'days_with_data': steps.length,
        'avg_steps': steps.isEmpty
            ? null
            : avg(steps.values.map((s) => s.value)).round(),
        'days_goal_met': steps.values
            .where((s) => s.value >= (profile?.stepGoal ?? 10000))
            .length,
      },
      'workouts': workouts.length,
      'runs': {
        'count': runs.where((r) => r.sportType == 'run').length,
        'distance_km': r2(
          runs
                  .where((r) => r.sportType == 'run')
                  .fold<double>(0, (a, r) => a + (r.distanceM ?? 0)) /
              1000,
        ),
      },
      'habit_completion_rate': habits['completion_rate'],
      'mood_avg': moods.isEmpty
          ? null
          : r1(avg(moods.map((m) => m.mood.toDouble()))),
      'missing': [
        if (logged.length < range.length)
          'food logged on ${logged.length} of ${range.length} days',
        if (steps.length < range.length)
          'steps synced on ${steps.length} of ${range.length} days',
      ],
      'provenance': provenance(
        sources: [
          'Food log',
          'Water log',
          'Workouts',
          'Habit tracker',
          'Mood log',
          ...steps.values.map((s) => sourceLabel(s.origin)),
        ],
        asOf: ctx.now,
        range: range,
        note: 'Calculated on-device. Strava activities excluded by policy.',
      ),
    };
  },
);
