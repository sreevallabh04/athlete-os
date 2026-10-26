# Notifications & reminders

Athlete OS reminders are **local, zoned notifications** scheduled on the phone
with `flutter_local_notifications` (Android `AlarmManager` underneath). There is
**no server push**: nothing about your reminders leaves the device, and
reminders work offline.

Code lives in `lib/features/life/`:

| Piece | File |
| --- | --- |
| Kinds, config JSON, id ranges, channels | `domain/reminder_kinds.dart` |
| Pure time planner (window, interval, quiet hours, busy, DST, max/day) | `domain/reminder_scheduler.dart` |
| Plan builder (prefs + habits + milestones → concrete notifications) | `domain/reminder_plan.dart` |
| Plugin seam (testable) | `application/notifications/notification_gateway.dart` |
| Reschedule service | `application/notifications/reminder_service.dart` |
| Background action handler (`@pragma('vm:entry-point')`) | `application/notifications/notification_actions.dart` |
| Start-up (timezone, init, auto-reschedule) | `bootstrap.dart` |
| Settings UI | `presentation/notification_settings_screen.dart` |

## Kinds

All kinds are **disabled by default** and stored in the `notification_prefs`
table (`kind`, `enabled`, `configJson`).

| Kind (`kind` key) | Default config | Channel | Notes |
| --- | --- | --- | --- |
| Water (`water`) | every 2 h inside wake window, max 8/day | Hydration | Actions **Log 250 ml** and **Snooze 30 min** |
| Habits (`habit`) | per-habit `reminderTimes` | Habits | Only on days the habit is due; skipped if already marked today; weekly-target habits stop for the week once the target is met |
| Daily planning (`planning`) | 08:00 daily | Planning & reviews | |
| Mood check-in (`mood`) | 20:30 daily | Well-being | |
| Journaling (`journal`) | 21:30 daily | Well-being | |
| Meal logging (`meal`) | 08:30, 13:00, 19:30 | Training & nutrition | |
| End-of-day review (`eod_review`) | 21:00 daily | Planning & reviews | |
| Weekly summary (`weekly_summary`) | Sunday 19:00 | Summaries & tests | |
| Workout (`workout`) | Mon/Wed/Fri 17:30 | Training & nutrition | |
| Step check (`steps`) | 18:00 daily | Training & nutrition | Text is deliberately generic ("Check your step progress for today") because the app can't reliably read steps in the background |
| Competition milestones (`competition`) | 08:00 morning-of | Competition prep | One per not-done `competition_milestones` row with a `dueDate` (competition not deleted), up to 60 days ahead |
| Posing practice (`posing`) | Tue/Thu/Sat 19:00 | Competition prep | |

Config JSON shape (lenient; missing fields fall back to defaults):
`{"times":[480],"daysMask":127,"intervalMinutes":120,"maxPerDay":8}` —
`times` are minutes after local midnight, `daysMask` bit0 = Monday … bit6 =
Sunday.

Copy is neutral and never guilt-based ("Mark it done or skip it — both are
fine").

### Lock-screen privacy

Reminders whose copy contains your own content — habit reminders (the habit
name is the title) and competition milestones (milestone title in the body)
— are posted with `NotificationVisibility.private`, so a secure lock screen
shows only "Contents hidden". Kinds with fixed, generic copy stay public.
See docs/PRIVACY.md → Lock screen.

## Scheduling mechanism

1. `lifeBootstrap` loads timezone data, sets `tz.local` from
   `FlutterTimezone.getLocalTimezone()`, initialises the plugin and creates the
   Android channels.
2. It listens to table changes (`notification_prefs`, `habits`,
   `habit_completions`, `app_settings`, `user_profiles`, `competitions`,
   `competition_milestones`) and calls `ReminderService.scheduleSoon()`
   (2-second debounce). The first emission performs the start-up reschedule.
3. `rescheduleAll()` is **idempotent** and serialised: it builds the full plan
   for the next **7 days**, cancels every pending notification whose id falls in
   any kind's id block, then schedules the new plan.

Stable ids: kind *k* owns `[k.block × 10000, k.block × 10000 + 10000)`; within a
kind, ids are assigned in chronological order. Each kind is capped at 120
pending notifications so the total stays well below Android's ~500 pending
alarm limit. Special ids: `1` = test notification, `2` = water snooze.

The planner works in wall-clock time in the device zone using
`tz.TZDateTime`, so a 09:00 reminder is at 09:00 local time on both sides of a
DST change. A time that falls in a spring-forward gap fires once just after the
gap; an ambiguous fall-back time fires once. Results are de-duplicated to the
minute and capped at the configured max per day.

Because plans cover 7 days and are refreshed on every app start and data
change, **open the app at least once a week**. If the device timezone is
unknown, `tz.local` stays UTC and reminders may fire at shifted wall-clock
times until the next successful start.

## Wake window, quiet hours and calendar awareness

* **Wake window** (`user_profiles.wakeMinutes` → `sleepMinutes`) applies to
  interval reminders (water). A sleep time earlier than the wake time means
  "after midnight".
* **Quiet hours** (`SettingKeys.quietHours`, JSON `{"start":1320,"end":420}`,
  minutes) are global: no reminder of any kind is scheduled inside them.
  Overnight ranges (start > end) are supported; `start == end` or `null` means
  off. Fixed-time reminders that land in quiet hours are dropped for that day,
  not moved.
* **Calendar-aware** (`SettingKeys.calendarAwareReminders`): when on, busy,
  non-all-day events from `calendarReaderProvider` for the plan horizon are
  treated as busy blocks. Interval reminders inside a busy block are dropped
  (another follows soon); fixed reminders move to the end of the (merged) block
  if that is ≤ 3 hours later, still the same day and not in quiet hours,
  otherwise they keep their original time. If the calendar is not connected
  (the default reader) or the read fails, reminders use the normal schedule and
  the settings screen says so.

## Exact vs inexact alarms

On each reschedule the service asks `canScheduleExactNotifications()`:

* **allowed** → `AndroidScheduleMode.exactAllowWhileIdle` (fires on time even
  in Doze, subject to Android's rate limits);
* **not allowed** (default on Android 14+ for new installs) →
  `AndroidScheduleMode.inexactAllowWhileIdle`; Android may batch and delay the
  reminder, typically by minutes, sometimes longer in deep Doze.

Exact alarms are optional. The settings screen offers "Allow precise timing",
which opens the system "Alarms & reminders" page
(`requestExactAlarmsPermission`).

## Permissions

* Android 13+ requires `POST_NOTIFICATIONS`. The app **explains first** (dialog)
  and only then shows the system prompt — when a reminder is first switched on
  or a test notification is sent.
* If notifications are disabled, the settings screen shows a banner with an
  "Allow" action; reminders are still planned so they work once allowed.

## Doze, battery restrictions and OEM behaviour

* Android Doze and App Standby can delay inexact alarms. Samsung One UI adds
  "Sleeping apps"/"Deep sleeping apps" lists that can suppress alarms
  entirely. The settings screen explains: Settings › Battery › Background usage
  limits (remove Athlete OS from sleeping lists) and Settings › Apps ›
  Athlete OS › Battery › Unrestricted.
* There is no package in the project to deep-link to the battery-optimisation
  screen, so the UI gives instructions plus a button to the app's notification
  settings (`openAppNotificationSettings`).
* **Force-stop** clears all scheduled alarms until the app is opened again.
  Reboots are handled by the plugin's `ScheduledNotificationBootReceiver`
  (declared in the manifest).

## Notification actions and their limits

Water reminders carry **Log 250 ml** and **Snooze 30 min**
(`showsUserInterface: false`). On Android these run in a **separate background
isolate** via `notificationBackgroundHandler`
(`@pragma('vm:entry-point')`, top-level), even when the app is open:

* **Log 250 ml** opens its own `AppDatabase()`, inserts a `water_logs` row via
  `WaterRepository.add(250, source: 'notification')` and closes the database.
  The row id is a stable UUID derived from the notification id + payload, so a
  duplicated callback can't double-log.
* **Snooze 30 min** schedules a one-off copy of the water reminder (id `2`) 30
  minutes later, inexact.

Limits: the background engine can be delayed or blocked by heavy battery
restrictions or after a force-stop; when the app is open, screens backed by
Drift streams won't see the background write until their tables change again
(a separate isolate/connection doesn't notify the main isolate's streams).
Plain taps open the app and navigate to the relevant screen (water → Hydration,
habit → Habits, mood → Mood, …).

## How to test

Automated (no device needed):

```
flutter test test/features/life/reminder_scheduler_test.dart   # window, interval, quiet hours, busy, DST, max/day
flutter test test/features/life/reminder_service_test.dart     # idempotent reschedule, habits, quiet hours, calendar, actions
```

On a device:

1. Life › Reminders (or Settings › Notifications). Tap **Send test
   notification** — you should be asked for permission first (Android 13+).
2. Enable **Water** with "every 1 h"; tap **Re-plan reminders now**; the status
   line shows how many reminders were planned.
3. To check delivery quickly, set your profile wake time just before now, or
   enable **Mood check-in** with a time 2 minutes ahead.
4. When a water reminder arrives, tap **Log 250 ml** without opening the app,
   then open Hydration: a 250 ml entry with source "notification" exists.
5. Inspect pending alarms: `adb shell dumpsys alarm | grep athlete_os`.
6. Simulate Doze: `adb shell dumpsys deviceidle force-idle` (and
   `adb shell dumpsys deviceidle unforce` afterwards) to compare exact vs
   inexact behaviour.
