# Android permissions & capabilities

Everything declared in `android/app/src/main/AndroidManifest.xml`, why it is
there and how to revoke it. The in-app **Settings › Permissions &
capabilities** screen (`/settings/capabilities`) shows the same with live
status, and always explains before sending you to a system page.

| Permission / component | Why | Requested | How to revoke |
| --- | --- | --- | --- |
| `INTERNET` | Food databases, Strava, Google Calendar, AI backend. | Install time | Not revocable (normal permission). |
| `POST_NOTIFICATIONS` | Reminders, briefings, approval prompts, Assistant mode notice. | Runtime, after an in-app explanation | App info › Notifications. |
| `RECEIVE_BOOT_COMPLETED` | Re-schedule reminders after reboot (flutter_local_notifications). | Install time | Not revocable; disable reminders in-app. |
| `SCHEDULE_EXACT_ALARM` | Reminders at the exact minute. | Special access, after explanation | Settings › Apps › Special app access › Alarms & reminders. |
| `VIBRATE` | Notification vibration. | Install time | Notification channel settings. |
| `CAMERA` (+ optional `android.hardware.camera`) | Barcode scanning, meal photos. | Runtime, first scan | App info › Permissions › Camera. |
| `android.permission.health.READ_*` (steps, distance, exercise, active/total calories, heart rate, resting HR, sleep, weight, history) | Read-only Health Connect data for dashboards and briefings. | Health Connect permission sheet, per feature | Health Connect › App permissions › Athlete OS. |
| `ViewPermissionUsageActivity` alias + `ACTION_SHOW_PERMISSIONS_RATIONALE` | Health Connect privacy-policy entry points. | — | — |
| `AssistantNotificationListener` (`BIND_NOTIFICATION_LISTENER_SERVICE`) | Read notifications from the messaging apps you enable; reply via their own reply action when you tap Send. | Notification access page, after an in-app explanation. Sideloaded on Android 13: App info › ⋮ › Allow restricted settings first. | Settings › Notifications › Notification access › Athlete OS assistant; or the in-app Emergency stop. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `AssistantForegroundService` (`foregroundServiceType="specialUse"`, subtype "personal assistant notification triage") | Optional, user-started "Assistant mode" that keeps the process alive on an always-on phone, with a persistent low-priority notification. | You turn it on in the app | Tap **Stop** on its notification or turn it off in the app. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Ask to be exempted from battery optimisation (sideloaded app; ColorOS kills background apps). | System dialog, after explanation | Settings › Battery › App battery management › Athlete OS › Optimise. Also undo "Allow background activity / auto launch". |
| `<queries>`: `MAIN`+`LAUNCHER` intent | List launchable apps for per-app assistant settings; open the app for "Copy & open". | — (package visibility) | Not a runtime permission. |
| `<queries>`: Health Connect / Samsung Health packages, `VIEW https`, Custom Tabs, `PROCESS_TEXT` | Health Connect detection, OAuth browser flows. | — | — |
| `CallbackActivity` (`athleteos://`) | Strava OAuth redirect. | — | Disconnect Strava in Integrations. |
| MainActivity `ACTION_SEND text/plain` intent-filter | Share text into the app (draft a reply, log food, ask coach). | You choose Athlete OS in the share sheet | Nothing to revoke; only what you share is received. |

## Not used

- **Accessibility service** — not declared. Android's accessibility policy
  requires a genuine accessibility use case; automating other apps is not one,
  and it would expose everything on screen. Notification access + RemoteInput
  reply actions are the narrower mechanism.
- No SMS/contacts/call-log permissions: SMS replies go through the messaging
  app's own notification reply action.

## Emergency disable

The kill switch (Assistant screen, Assistant settings, Permissions &
capabilities) immediately tells the native listener to ignore everything,
clears its queue, stops Assistant mode and refuses all sends. To remove access
entirely, also turn off notification access.
