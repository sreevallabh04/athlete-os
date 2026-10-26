import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../../core/contracts/calendar_reader.dart';
import '../../../../core/domain/free_slots.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/redact.dart';
import '../../../../data/db/database.dart';
import '../../../../data/repositories/settings_repository.dart';
import '../../data/notification_prefs_repository.dart';
import '../../domain/reminder_kinds.dart';
import '../../domain/reminder_plan.dart';
import '../../domain/reminder_scheduler.dart';
import '../habit_providers.dart';
import 'notification_gateway.dart';

/// How calendar awareness was applied in the last reschedule.
enum CalendarAwareness { off, applied, notConnected, failed }

class RescheduleResult {
  const RescheduleResult({
    required this.scheduled,
    required this.exact,
    required this.calendar,
    required this.at,
    this.byKind = const {},
  });
  final int scheduled;
  final bool exact;
  final CalendarAwareness calendar;
  final DateTime at;
  final Map<ReminderKind, int> byKind;
}

/// Plans and (re)schedules every local reminder. Idempotent: each run cancels
/// the pending ids owned by every kind, then schedules the fresh plan.
class ReminderService {
  ReminderService({
    required this.gateway,
    required this.db,
    required this.clock,
    required this.calendarReader,
    required this.habitBoardLoader,
    tz.Location Function()? location,
    this.horizonDays = 7,
  }) : _location = location ?? (() => tz.local);

  final NotificationGateway gateway;
  final AppDatabase db;
  final Clock clock;
  final CalendarReader calendarReader;
  final HabitBoardLoader habitBoardLoader;
  final tz.Location Function() _location;
  final int horizonDays;

  bool _initialized = false;
  bool get initialized => _initialized;
  Future<void> _queue = Future.value();
  Timer? _debounce;
  RescheduleResult? lastResult;

  /// Initialises the plugin and channels. Never throws.
  Future<bool> init({required void Function(NotificationTap) onTap}) async {
    try {
      _initialized = await gateway.initialize(onTap: onTap);
      if (_initialized) {
        await gateway.createChannels(ReminderChannel.values);
      }
    } catch (e) {
      debugPrint('Notification init failed: ${redactSecrets(e.toString())}');
      _initialized = false;
    }
    return _initialized;
  }

  /// Debounced reschedule used by change listeners.
  void scheduleSoon([Duration delay = const Duration(seconds: 2)]) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(rescheduleAll()));
  }

  void dispose() => _debounce?.cancel();

  /// Serialised so overlapping triggers never interleave cancel/schedule.
  Future<RescheduleResult?> rescheduleAll() {
    final run = _queue.then((_) => _reschedule());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<RescheduleResult?> _reschedule() async {
    try {
      final input = await buildPlanInput();
      final plan = buildReminderPlan(input.$1);
      final pending = await gateway.pendingIds();
      for (final id in pending) {
        if (ReminderKind.forId(id) != null) await gateway.cancel(id);
      }
      final exact = await gateway.canScheduleExact() ?? false;
      final byKind = <ReminderKind, int>{};
      for (final p in plan) {
        await gateway.schedule(
          NotificationRequest(
            id: p.id,
            title: p.title,
            body: p.body,
            channel: p.kind.channel,
            payload: p.payload,
            waterActions: p.kind == ReminderKind.water,
            personal: !p.kind.isGenericCopy(p.title, p.body),
          ),
          p.when,
          exact: exact,
        );
        byKind[p.kind] = (byKind[p.kind] ?? 0) + 1;
      }
      return lastResult = RescheduleResult(
        scheduled: plan.length,
        exact: exact,
        calendar: input.$2,
        at: clock.now(),
        byKind: byKind,
      );
    } catch (e) {
      debugPrint('Reschedule failed: ${redactSecrets(e.toString())}');
      return null;
    }
  }

  /// Gathers preferences and app data into a plan input.
  Future<(ReminderPlanInput, CalendarAwareness)> buildPlanInput() async {
    final loc = _location();
    final now = tz.TZDateTime.from(clock.now(), loc);
    final prefs = await NotificationPrefsRepository(db, clock).all();
    final settings = SettingsRepository(db);
    final profile = await (db.select(
      db.userProfiles,
    )..where((p) => p.id.equals(1))).getSingleOrNull();
    QuietHours? quiet;
    try {
      quiet = QuietHours.fromJson(
        await settings.get<Object?>(SettingKeys.quietHours),
      );
    } catch (_) {
      quiet = null;
    }

    final anyEnabled = prefs.values.any((p) => p.enabled);
    var calendar = CalendarAwareness.off;
    var busy = <TimeInterval>[];
    bool calendarAware = false;
    try {
      calendarAware =
          await settings.get<bool>(SettingKeys.calendarAwareReminders) ?? false;
    } catch (_) {}
    if (anyEnabled && calendarAware) {
      try {
        final res = await calendarReader
            .eventsBetween(now, now.add(Duration(days: horizonDays + 1)))
            .timeout(const Duration(seconds: 10));
        if (!res.connected) {
          calendar = CalendarAwareness.notConnected;
        } else if (res.error != null) {
          calendar = CalendarAwareness.failed;
        } else {
          calendar = CalendarAwareness.applied;
          busy = [
            for (final e in res.events)
              if (e.isBusy && !e.allDay) TimeInterval(e.start, e.end),
          ];
        }
      } catch (_) {
        calendar = CalendarAwareness.failed;
      }
    }

    final habits = <HabitReminderSource>[];
    if (prefs[ReminderKind.habit]?.enabled ?? false) {
      final board = await habitBoardLoader.load(LocalDates.key(clock.now()));
      for (final h in board.habits) {
        if (h.reminderTimes.isEmpty) continue;
        habits.add(
          HabitReminderSource(
            id: h.id,
            name: h.name,
            reminderTimes: h.reminderTimes,
            schedule: h.schedule,
            startDate: h.startDate,
            marks: h.marks,
          ),
        );
      }
    }

    final milestones = <MilestoneReminderSource>[];
    if (prefs[ReminderKind.competition]?.enabled ?? false) {
      final comps = await (db.select(
        db.competitions,
      )..where((c) => c.deletedAt.isNull())).get();
      final names = {for (final c in comps) c.id: c.name};
      final rows = await (db.select(
        db.competitionMilestones,
      )..where((m) => m.done.equals(false) & m.dueDate.isNotNull())).get();
      for (final m in rows) {
        if (!names.containsKey(m.competitionId)) continue;
        milestones.add(
          MilestoneReminderSource(
            id: m.id,
            title: m.title,
            dueDate: m.dueDate!,
            competitionName: names[m.competitionId],
          ),
        );
      }
    }

    return (
      ReminderPlanInput(
        prefs: prefs,
        now: now,
        days: horizonDays,
        wakeMinutes: profile?.wakeMinutes ?? 390,
        sleepMinutes: profile?.sleepMinutes ?? 1350,
        quietHours: quiet,
        busy: busy,
        habits: habits,
        milestones: milestones,
      ),
      calendar,
    );
  }

  Future<void> sendTest() => gateway.show(
    const NotificationRequest(
      id: SpecialNotificationIds.test,
      title: 'Test notification',
      body: 'Notifications from Athlete OS are working.',
      channel: ReminderChannel.summaries,
      payload: '{"k":"test"}',
    ),
  );
}
