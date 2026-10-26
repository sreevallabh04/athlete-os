import 'dart:convert';

import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/life/application/habit_providers.dart';
import 'package:athlete_os/features/life/application/notifications/notification_actions.dart';
import 'package:athlete_os/features/life/application/notifications/notification_gateway.dart';
import 'package:athlete_os/features/life/application/notifications/notification_providers.dart';
import 'package:athlete_os/features/life/application/notifications/reminder_service.dart';
import 'package:athlete_os/features/life/data/auto_rule_repository.dart';
import 'package:athlete_os/features/life/data/habit_repository.dart';
import 'package:athlete_os/features/life/data/notification_prefs_repository.dart';
import 'package:athlete_os/features/life/domain/habit_models.dart';
import 'package:athlete_os/features/life/domain/reminder_kinds.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationVisibility;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../helpers/test_app.dart';
import 'fake_notification_gateway.dart';

class _BusyCalendar implements CalendarReader {
  _BusyCalendar(this.events);
  final List<CalendarEventView> events;
  @override
  Future<CalendarReadResult> eventsBetween(DateTime s, DateTime e) async =>
      CalendarReadResult.connected(events);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  // Monday 26 Oct 2026, 06:00 UTC.
  final now = DateTime.utc(2026, 10, 26, 6);
  late AppDatabase db;
  late FakeNotificationGateway gateway;
  late NotificationPrefsRepository prefs;
  late HabitRepository habits;

  ReminderService service({CalendarReader? calendar}) => ReminderService(
    gateway: gateway,
    db: db,
    clock: FixedClock(now),
    calendarReader: calendar ?? const DisconnectedCalendarReader(),
    habitBoardLoader: HabitBoardLoader(db, habits, AutoRuleRepository(db)),
    location: () => tz.getLocation('UTC'),
  );

  setUp(() async {
    db = newTestDb();
    gateway = FakeNotificationGateway();
    prefs = NotificationPrefsRepository(db, FixedClock(now));
    habits = HabitRepository(
      db,
      FixedClock(now.subtract(const Duration(days: 3))),
    );
    // Wake 07:00, sleep 22:00.
    await (db.update(db.userProfiles)..where((p) => p.id.equals(1))).write(
      const UserProfilesCompanion(
        wakeMinutes: Value(420),
        sleepMinutes: Value(1320),
      ),
    );
  });
  tearDown(() => db.close());

  test('everything is disabled by default: nothing scheduled', () async {
    final r = await service().rescheduleAll();
    expect(r!.scheduled, 0);
    expect(gateway.pending, isEmpty);
  });

  test('water: interval reminders with actions, ids in the water block, '
      'idempotent across runs', () async {
    await prefs.save(
      ReminderKind.water,
      enabled: true,
      config: const ReminderConfig(intervalMinutes: 180, maxPerDay: 4),
    );
    final s = service();
    await s.rescheduleAll();
    final first = Map.of(gateway.pending);
    // 10:00, 13:00, 16:00, 19:00 for 7 days.
    expect(first.length, 28);
    expect(first.keys.every(ReminderKind.water.ownsId), isTrue);
    expect(first.values.every((v) => v.$1.waterActions), isTrue);
    expect(first.values.every((v) => v.$3 == false), isTrue, reason: 'inexact');

    await s.rescheduleAll();
    expect(gateway.pending.keys.toSet(), first.keys.toSet());
    expect(
      gateway.pending.values.map((v) => v.$2).toList(),
      first.values.map((v) => v.$2).toList(),
    );

    // Disabling cancels everything in the block.
    await prefs.save(ReminderKind.water, enabled: false);
    await s.rescheduleAll();
    expect(gateway.pending, isEmpty);
  });

  test('exact alarms are used when the system allows them', () async {
    gateway.exact = true;
    await prefs.save(ReminderKind.planning, enabled: true);
    final r = await service().rescheduleAll();
    expect(r!.exact, isTrue);
    expect(gateway.pending.values.every((v) => v.$3), isTrue);
  });

  test('habit reminders skip today once the habit is marked', () async {
    await prefs.save(ReminderKind.habit, enabled: true);
    final id = await habits.create(
      const HabitInput(name: 'Read', reminderTimes: [21 * 60]),
    );
    await service().rescheduleAll();
    final dates = gateway.pending.values.map((v) => v.$2.day).toList();
    expect(dates.first, 26);
    expect(gateway.pending.values.first.$1.title, 'Read');
    final payload = jsonDecode(gateway.pending.values.first.$1.payload!) as Map;
    expect(payload['h'], id);

    await habits.setStatus(id, '2026-10-26', HabitStatus.done);
    await service().rescheduleAll();
    expect(gateway.pending.values.map((v) => v.$2.day).first, 27);
  });

  group('lock-screen privacy', () {
    test('habit names and milestone titles are private; generic copy stays '
        'public', () async {
      await prefs.save(ReminderKind.habit, enabled: true);
      await prefs.save(ReminderKind.water, enabled: true);
      await prefs.save(ReminderKind.competition, enabled: true);
      await habits.create(
        const HabitInput(name: 'Insulin check', reminderTimes: [21 * 60]),
      );
      await db
          .into(db.competitions)
          .insert(
            CompetitionsCompanion.insert(
              id: 'c1',
              name: 'Regional Classic',
              eventDate: '2027-03-01',
              tzName: 'UTC',
            ),
          );
      await db
          .into(db.competitionMilestones)
          .insert(
            CompetitionMilestonesCompanion.insert(
              id: 'm1',
              competitionId: 'c1',
              title: 'Book tan',
              dueDate: const Value('2026-11-10'),
            ),
          );
      await service().rescheduleAll();
      final requests = [for (final v in gateway.pending.values) v.$1];
      final habit = requests.firstWhere(
        (r) => ReminderKind.forId(r.id) == ReminderKind.habit,
      );
      final milestone = requests.firstWhere(
        (r) => ReminderKind.forId(r.id) == ReminderKind.competition,
      );
      final water = requests.firstWhere(
        (r) => ReminderKind.forId(r.id) == ReminderKind.water,
      );
      for (final personal in [habit, milestone]) {
        expect(personal.personal, isTrue);
        expect(
          notificationDetailsFor(personal).android!.visibility,
          NotificationVisibility.private,
        );
      }
      expect(water.personal, isFalse);
      expect(
        notificationDetailsFor(water).android!.visibility,
        NotificationVisibility.public,
      );
    });

    test('every generic reminder kind keeps public copy', () {
      for (final k in ReminderKind.values) {
        expect(k.isGenericCopy(k.title, k.body), isTrue);
        expect(k.isGenericCopy('Read', k.body), isFalse);
      }
      const test = NotificationRequest(
        id: SpecialNotificationIds.test,
        title: 'Test notification',
        body: 'Notifications from Athlete OS are working.',
        channel: ReminderChannel.summaries,
      );
      expect(
        notificationDetailsFor(test).android!.visibility,
        NotificationVisibility.public,
      );
    });
  });

  test('quiet hours setting suppresses reminders', () async {
    await SettingsRepository(db)
        .set(SettingKeys.quietHours, {'start': 1200, 'end': 420});
    await prefs.save(
      ReminderKind.mood,
      enabled: true,
      config: const ReminderConfig(times: [1230]),
    );
    await service().rescheduleAll();
    expect(gateway.pending, isEmpty);
  });

  test('calendar-aware: not connected is reported and ignored', () async {
    await SettingsRepository(db).set(SettingKeys.calendarAwareReminders, true);
    await prefs.save(ReminderKind.planning, enabled: true);
    final r = await service().rescheduleAll();
    expect(r!.calendar, CalendarAwareness.notConnected);
    expect(gateway.pending.length, 7);
  });

  test('calendar-aware: busy events shift fixed reminders', () async {
    await SettingsRepository(db).set(SettingKeys.calendarAwareReminders, true);
    await prefs.save(
      ReminderKind.planning,
      enabled: true,
      config: const ReminderConfig(times: [480]),
    );
    final r = await service(
      calendar: _BusyCalendar([
        CalendarEventView(
          id: 'e',
          calendarId: 'c',
          title: 'Standup',
          start: DateTime.utc(2026, 10, 26, 7, 45),
          end: DateTime.utc(2026, 10, 26, 8, 30),
        ),
      ]),
    ).rescheduleAll();
    expect(r!.calendar, CalendarAwareness.applied);
    final first = gateway.pending.values.map((v) => v.$2).toList()..sort();
    expect(first.first.hour, 8);
    expect(first.first.minute, 30);
  });

  test('competition milestones get morning-of reminders', () async {
    await db
        .into(db.competitions)
        .insert(
          CompetitionsCompanion.insert(
            id: 'c1',
            name: 'Regional Classic',
            eventDate: '2027-03-01',
            tzName: 'UTC',
          ),
        );
    await db
        .into(db.competitionMilestones)
        .insert(
          CompetitionMilestonesCompanion.insert(
            id: 'm1',
            competitionId: 'c1',
            title: 'Book tan',
            dueDate: const Value('2026-11-10'),
          ),
        );
    await prefs.save(ReminderKind.competition, enabled: true);
    await service().rescheduleAll();
    final v = gateway.pending.values.single;
    expect(v.$2.day, 10);
    expect(v.$2.hour, 8);
    expect(v.$1.body, 'Book tan · Regional Classic');
  });

  test('payload routes', () {
    expect(routeForPayload('{"k":"water"}'), '/hydration');
    expect(routeForPayload('{"k":"habit","h":"x"}'), '/habits');
    expect(routeForPayload('{"k":"weekly_summary"}'), '/reports');
    expect(routeForPayload('garbage'), isNull);
  });

  group('notification actions', () {
    test(
      '"Log 250 ml" logs once per notification with source notification',
      () async {
        const tap = NotificationTap(
          id: 10003,
          actionId: NotificationActionIds.logWater,
          payload: '{"k":"water","at":"2026-10-26T10:00:00.000Z"}',
        );
        final clock = FixedClock(now.add(const Duration(hours: 4)));
        await handleNotificationAction(
          tap,
          db: db,
          gateway: gateway,
          clock: clock,
        );
        await handleNotificationAction(
          tap,
          db: db,
          gateway: gateway,
          clock: clock,
        );
        final rows = await db.select(db.waterLogs).get();
        expect(rows.length, 1);
        expect(rows.single.amountMl, 250);
        expect(rows.single.source, 'notification');
      },
    );

    test('"Snooze 30 min" schedules a one-off water reminder', () async {
      const tap = NotificationTap(
        id: 10003,
        actionId: NotificationActionIds.snoozeWater,
      );
      await handleNotificationAction(
        tap,
        db: db,
        gateway: gateway,
        clock: FixedClock(now),
      );
      final v = gateway.pending[SpecialNotificationIds.waterSnooze]!;
      expect(
        v.$2.millisecondsSinceEpoch,
        now.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      );
      expect(v.$1.waterActions, isTrue);
    });
  });
}
