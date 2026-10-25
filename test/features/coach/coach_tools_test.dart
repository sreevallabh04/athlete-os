import 'dart:convert';

import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/coach/tools/life_tools.dart';
import 'package:athlete_os/features/coach/tools/tool_registry.dart';
import 'package:athlete_os/features/coach/tools/tool_spec.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

Future<Map<String, Object?>> run(
  AppDatabase db,
  String name, [
  Map<String, Object?> args = const {},
  ToolContext? ctx,
]) => toolByName(name)!.handler(ctx ?? toolContext(db), args);

class _FakeCalendar implements CalendarReader {
  const _FakeCalendar(this.events);
  final List<CalendarEventView> events;
  @override
  Future<CalendarReadResult> eventsBetween(DateTime s, DateTime e) async =>
      CalendarReadResult.connected(
        events,
        fetchedAt: DateTime(2026, 10, 25, 8),
      );
}

void main() {
  late AppDatabase db;
  setUp(() => db = newTestDb());
  tearDown(() => db.close());

  test(
    'nutrition totals exclude soft-deleted rows and compute remaining',
    () async {
      await addFood(db, id: 'a', date: testToday, kcal: 500, protein: 40);
      await addFood(db, id: 'b', date: testToday, kcal: 300, protein: 20);
      await addFood(
        db,
        id: 'c',
        date: testToday,
        kcal: 900,
        protein: 90,
        deleted: true,
      );
      await addFood(db, id: 'd', date: '2026-10-24', kcal: 1000, protein: 10);
      final r = await run(db, 'get_nutrition_summary');
      final totals = r['totals'] as Map;
      expect(totals['calories_kcal'], 800);
      expect(totals['protein_g'], 60);
      expect(totals['entries'], 2);
      // Defaults: 2000 kcal, 150 g protein.
      expect((r['remaining'] as Map)['protein_g'], 90);
      expect((r['remaining'] as Map)['calories_kcal'], 1200);
      expect((r['entries'] as List).map((e) => (e as Map)['id']), ['a', 'b']);
      expect((r['provenance'] as Map)['date_range'], {
        'start': testToday,
        'end': testToday,
      });

      final range = await run(db, 'get_nutrition_summary', {
        'start_date': '2026-10-23',
        'end_date': testToday,
      });
      expect(range['days_logged'], 2);
      expect(range['missing'], ['no food logged on 2026-10-23']);
    },
  );

  test('ranges are bounded and validated', () async {
    expect(
      () => run(db, 'get_nutrition_summary', {
        'start_date': '2026-01-01',
        'end_date': testToday,
      }),
      throwsArgumentError,
    );
    expect(
      () => run(db, 'get_nutrition_summary', {
        'start_date': '2026-10-26',
        'end_date': testToday,
      }),
      throwsArgumentError,
    );
  });

  test(
    'log_food marks unmatched items as estimates and scales stored foods',
    () async {
      await db
          .into(db.foods)
          .insert(
            FoodsCompanion.insert(
              id: 'paneer',
              name: 'Paneer',
              calories: 265,
              proteinG: const Value(18),
              source: 'usda',
              verification: 'database',
            ),
          );
      final r = await run(db, 'log_food', {
        'meal_type': 'dinner',
        'items': [
          {'name': 'Paneer', 'food_id': 'paneer', 'grams': 200},
          {'name': 'Dal', 'calories': 180, 'protein_g': 9},
        ],
      });
      expect(r['status'], 'logged');
      final rows = await (db.select(
        db.foodLogEntries,
      )..orderBy([(f) => OrderingTerm.asc(f.calories)])).get();
      expect(rows, hasLength(2));
      final dal = rows.first;
      final paneer = rows.last;
      expect(dal.verification, 'estimate');
      expect(dal.source, 'ai_estimate');
      expect(paneer.verification, 'database');
      expect(paneer.calories, closeTo(530, 0.001));
      expect(paneer.proteinG, closeTo(36, 0.001));
      expect((r['day_totals'] as Map)['calories_kcal'], 710);

      // Same tool call again → deterministic ids, no duplicates.
      await run(db, 'log_food', {
        'meal_type': 'dinner',
        'items': [
          {'name': 'Paneer', 'food_id': 'paneer', 'grams': 200},
          {'name': 'Dal', 'calories': 180, 'protein_g': 9},
        ],
      });
      expect(await db.select(db.foodLogEntries).get(), hasLength(2));

      expect(
        () => run(db, 'log_food', {
          'date': '2026-10-26',
          'meal_type': 'lunch',
          'items': [
            {'name': 'x', 'calories': 1},
          ],
        }),
        throwsArgumentError,
      );
    },
  );

  test('steps summary prefers Health Connect and computes remaining', () async {
    Future<void> steps(String date, double v, String origin, DateTime at) => db
        .into(db.dailyHealthSummaries)
        .insert(
          DailyHealthSummariesCompanion.insert(
            localDate: date,
            type: 'steps',
            value: v,
            unit: 'count',
            origin: origin,
            computedAt: Value(at),
          ),
        );
    await steps(
      testToday,
      6200,
      'health_connect',
      DateTime(2026, 10, 25, 8, 30),
    );
    await steps(testToday, 9999, 'manual', DateTime(2026, 10, 25, 8));
    final r = await run(db, 'get_steps_summary');
    final today = r['today'] as Map;
    expect(today['steps'], 6200);
    expect(today['remaining_to_goal'], 3800);
    expect(today['stale'], false);
    expect((r['provenance'] as Map)['sources'], ['Health Connect']);

    final stale = await run(
      db,
      'get_steps_summary',
      const {},
      toolContext(db, now: DateTime(2026, 10, 25, 13)),
    );
    expect((stale['today'] as Map)['stale'], true);
    final empty = await run(db, 'get_steps_summary', {'date': '2026-10-20'});
    expect(empty['missing'], ['no step data for 2026-10-20']);
  });

  test('competition countdown counts calendar days in the event timezone', () {
    // 20:00 UTC Oct 25 = 01:30 Oct 26 in Kolkata, 13:00 Oct 25 in LA.
    final now = DateTime.utc(2026, 10, 25, 20);
    final kolkata = daysUntilEvent('2026-11-01', 'Asia/Kolkata', now);
    expect(kolkata.todayInEventTz, '2026-10-26');
    expect(kolkata.days, 6);
    final la = daysUntilEvent('2026-11-01', 'America/Los_Angeles', now);
    expect(la.todayInEventTz, '2026-10-25');
    expect(la.days, 7);
    // Across the US DST change (Nov 1 2026) still whole calendar days.
    final dst = daysUntilEvent(
      '2026-11-08',
      'America/New_York',
      DateTime.utc(2026, 10, 31, 16),
    );
    expect(dst.days, 8);
    final unknown = daysUntilEvent('2026-11-01', 'Mars/Olympus', now);
    expect(unknown.tzKnown, isFalse);
  });

  test(
    'get_competition_countdown returns upcoming events with milestones',
    () async {
      await db
          .into(db.competitions)
          .insert(
            CompetitionsCompanion.insert(
              id: 'comp',
              name: 'State Classic',
              eventDate: '2026-12-05',
              tzName: 'Asia/Kolkata',
            ),
          );
      await db
          .into(db.competitionMilestones)
          .insert(
            CompetitionMilestonesCompanion.insert(
              id: 'm1',
              competitionId: 'comp',
              title: 'Book posing coach',
              dueDate: const Value('2026-11-01'),
            ),
          );
      final r = await run(
        db,
        'get_competition_countdown',
        const {},
        toolContext(db, now: DateTime.utc(2026, 10, 25, 3)),
      );
      final c = (r['competitions'] as List).single as Map;
      expect(c['days_until'], 41);
      expect((c['open_milestones'] as List).single, {
        'title': 'Book posing coach',
        'due': '2026-11-01',
      });
    },
  );

  test(
    'suggest_schedule avoids busy events and reports calendar state',
    () async {
      final noCal = await run(db, 'suggest_schedule', {'duration_min': 45});
      expect(noCal['calendar_checked'], false);
      expect(
        (noCal['missing'] as List).first,
        contains('calendar not connected'),
      );
      // Today at 09:00 → first slot starts now.
      expect(
        ((noCal['candidate_slots'] as List).first as Map)['start'],
        '09:00',
      );

      final cal = _FakeCalendar([
        CalendarEventView(
          id: 'e1',
          calendarId: 'p',
          title: 'Work',
          start: DateTime(2026, 10, 25, 9),
          end: DateTime(2026, 10, 25, 17),
        ),
      ]);
      final r = await run(db, 'suggest_schedule', {
        'duration_min': 45,
        'buffer_min': 15,
      }, toolContext(db, calendar: cal));
      expect(r['calendar_checked'], true);
      final first = (r['candidate_slots'] as List).first as Map;
      expect(first['start'], '17:15');
      expect(first['end'], '18:00');
      expect(await db.select(db.calendarEventRefs).get(), isEmpty);
    },
  );

  test('get_calendar_events reports not-connected honestly', () async {
    final r = await run(db, 'get_calendar_events');
    expect(r['connected'], false);
    expect(r['events'], isEmpty);
  });

  test('habit summary computes due, done and streaks', () async {
    await db
        .into(db.habits)
        .insert(HabitsCompanion.insert(id: 'h', name: 'Stretch'));
    for (final d in ['2026-10-23', '2026-10-24', '2026-10-25']) {
      await db
          .into(db.habitCompletions)
          .insert(
            HabitCompletionsCompanion.insert(
              id: 'hc$d',
              habitId: 'h',
              localDate: d,
            ),
          );
    }
    final r = await run(db, 'get_habit_summary');
    final h = (r['habits'] as List).single as Map;
    expect(h['due'], 7);
    expect(h['done'], 3);
    expect(h['streak_days'], 3);
    expect(h['done_today'], true);
  });

  test('remember_preference stores an unapproved suggestion', () async {
    final r = await run(db, 'remember_preference', {
      'category': 'routine',
      'content': 'Trains at 6 am',
    });
    expect(r['status'], 'pending_user_approval');
    final m = await db.select(db.aiMemories).getSingle();
    expect(m.approved, isFalse);
    expect(m.origin, 'ai_suggested');
    final again = await run(db, 'remember_preference', {
      'category': 'routine',
      'content': 'trains at 6 am',
    });
    expect(again['status'], 'already_pending');
  });

  test('Strava data never appears in any tool output', () async {
    const secret = 'STRAVA_SECRET_RUN_42';
    await db
        .into(db.cardioActivities)
        .insert(
          CardioActivitiesCompanion.insert(
            id: 'strava-1',
            source: 'strava',
            externalId: const Value('987654321'),
            name: const Value(secret),
            sportType: 'run',
            startAt: DateTime.utc(2026, 10, 25, 1),
            localDate: testToday,
            distanceM: const Value(12345),
          ),
        );
    await db
        .into(db.cardioActivities)
        .insert(
          CardioActivitiesCompanion.insert(
            id: 'hc-1',
            source: 'health_connect',
            name: const Value('Easy run'),
            sportType: 'run',
            startAt: DateTime.utc(2026, 10, 24, 1),
            localDate: '2026-10-24',
            distanceM: const Value(5000),
            movingTimeS: const Value(1500),
          ),
        );
    await db
        .into(db.healthSamples)
        .insert(
          HealthSamplesCompanion.insert(
            id: 's1',
            type: 'weight',
            value: 77.7,
            unit: 'kg',
            startAt: DateTime.utc(2026, 10, 25),
            endAt: DateTime.utc(2026, 10, 25),
            localDate: testToday,
            sourceApp: const Value('com.strava'),
            origin: 'health_connect',
          ),
        );
    final outputs = <String>[];
    final ctx = toolContext(db);
    for (final t in coachTools.where((t) => !t.isWrite)) {
      if (t.name == 'remember_preference' ||
          t.name == 'record_recommendation') {
        continue;
      }
      final args = switch (t.name) {
        'search_food_database' => {'query': 'run'},
        'get_strength_progress' => {'exercise': 'run'},
        'suggest_schedule' => {'duration_min': 30},
        'get_running_activities' => {'sport_type': 'any'},
        _ => const <String, Object?>{},
      };
      outputs.add(jsonEncode(await t.handler(ctx, args)));
    }
    final all = outputs.join('\n');
    expect(all, isNot(contains(secret)));
    expect(all, isNot(contains('987654321')));
    expect(all, isNot(contains('strava-1')));
    expect(all, isNot(contains('12.35'))); // 12345 m as km
    expect(all, isNot(contains('77.7')));
    expect(all, contains('Easy run'));

    final notice = await run(db, 'get_strava_activities');
    expect(notice['status'], 'unavailable_by_policy');
    final analyze = await run(db, 'analyze_strava_activity', {
      'activity_id': 'strava-1',
    });
    expect(jsonEncode(analyze), isNot(contains(secret)));
    expect(analyze['message'], contains('Running screen'));
  });

  test('weekly report aggregates deterministically', () async {
    await addFood(db, id: 'w1', date: '2026-10-19', kcal: 2000, protein: 150);
    await addFood(db, id: 'w2', date: '2026-10-20', kcal: 1500, protein: 100);
    final r = await run(db, 'get_weekly_report');
    expect((r['week'] as Map)['start'], '2026-10-19');
    final n = r['nutrition'] as Map;
    expect(n['days_logged'], 2);
    expect(n['avg_calories_kcal'], 1750);
    expect(n['days_within_10pct_of_calorie_target'], 1);
    expect(n['days_protein_at_least_90pct'], 1);
  });

  test('today dashboard lists what is missing', () async {
    final r = await run(db, 'get_today_dashboard');
    expect(r['date'], testToday);
    expect(r['missing'], contains('no food logged today'));
    expect(r['missing'], contains('no step data synced today'));
  });
}
