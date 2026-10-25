# Athlete OS — Privacy

Athlete OS is a single-user, local-first app for fitness, nutrition, health
and personal productivity. This document describes what the app collects,
where it is stored, where it can flow, and how you stay in control. The
in-app **Settings → Privacy & data** screen is the plain-language version of
this document.

## 1. Data collected

| Category | Examples | Origin |
| --- | --- | --- |
| Profile & goals | name, height, target weight, diet type, restrictions, disliked foods, calorie/macro/step/water targets, wake/sleep times, coaching style, running goal, goal-change history | You |
| Injuries & restrictions | description, body part, what to avoid, clinician-imposed flag, dates | You |
| Nutrition | food log entries (nutrient snapshot, source, verification level), custom foods, recipes, saved meals | You, Open Food Facts, USDA, optional AI estimates |
| Hydration | water log entries | You, notification actions, AI coach (with confirmation) |
| Health | steps, distance, active minutes, active energy, sleep, heart rate, resting heart rate, weight, exercise sessions | Health Connect, manual entry |
| Training | strength workouts, exercises and sets | Hevy, manual entry, CSV import |
| Cardio | runs, walks, rides with distance, time, pace, heart rate, splits | Strava, Health Connect, manual entry |
| Well-being | habits and completions, mood check-ins, journal entries | You |
| Planning | tasks/priorities, end-of-day notes, weekly reviews, calendar events read from Google Calendar (not stored unless the app created them) | You, Google Calendar |
| Competition prep | competition date/timezone/location/division, milestones, checklist, **progress photos** | You |
| AI coach | conversations, approved long-term memory, recommendations, an audit log of every tool action | You and the AI coach |
| Reports | generated weekly/monthly report snapshots | Computed on-device |
| Integration status | connection state, last sync time, sync cursors (never tokens) | App |

## 2. Storage locations

* **On-device SQLite database** (app-private storage) holds all of the data
  above. It is not readable by other apps.
* **Progress photos** are copied into the app's private documents directory
  (`progress_photos/`). They are **never uploaded** — not to the backend, not
  to any AI provider — and are excluded from the JSON export (only their dates
  are exported).
* **Secrets** (OAuth tokens, Hevy API key) are kept in the platform secure
  storage (Android Keystore-backed), never in the database or in exports.
* **Optional Supabase backend.** If you configure your own backend, records
  may be synced to it. Every table is protected by row-level security so only
  your authenticated account can read or write your rows. The app works fully
  offline without a backend.

## 3. Third-party data flows

| Service | What flows | Direction | Notes |
| --- | --- | --- | --- |
| Health Connect | steps, distance, active minutes/energy, sleep, heart rate, weight, exercise sessions | Read into the app (writes only for data you log, if enabled) | Permissions are granted per data type and can be revoked in Android settings. |
| Hevy | workouts, exercises, sets | Read into the app | Uses your personal API key. |
| Strava | your activities | Read into the app | Shown with "Powered by Strava". **Strava data is never sent to any AI provider** (Strava API Agreement / Policy §5.3) and is not combined with other users' data. |
| Google Calendar | event titles/times for the days you view; events you explicitly ask the app to create | Read, and write only on your request | OAuth scopes are limited to calendar access. |
| Open Food Facts | barcode / text searches | Query sent; product data received | Food data © Open Food Facts contributors, ODbL. |
| USDA FoodData Central | text searches | Query sent; nutrient data received | Public-domain data. |
| AI providers | your messages and — **only with explicit consent** — summarised health data, journal text and meal photos | Via the Athlete OS backend only | Provider API keys live on the backend, never in the app. Consents are off by default and can be changed any time in Privacy & data. Progress photos and Strava data are never sent. |

The deterministic features (Today summary, competition countdown, reports,
planner suggestions, adherence calculations) run entirely on-device and do not
use AI.

## 4. Retention

* Local data is kept until you delete it (per category or everything) or
  uninstall the app.
* **Strava data** is refreshed or purged within **7 days** of being fetched,
  and all Strava-derived data is deleted within **30 days** of disconnecting
  Strava (or immediately when you delete it).
* Calendar events that the app only reads are not persisted.
* Saved reports are snapshots and stay until you delete them.
* Backend copies (if enabled) are deleted when you delete the corresponding
  local data or your account.

## 5. Permissions (Android)

| Permission | Why |
| --- | --- |
| Health Connect read (and optional write) permissions | Sync steps, sleep, heart rate, weight and exercise data |
| Camera | Barcode scanning and taking progress/meal photos (only when you tap) |
| Photos / media picker | Choose existing photos (system picker, no broad storage access) |
| Notifications, exact alarms | Reminders you configure (water, habits, planning, reviews) |
| Internet | Integrations, food databases, optional backend and AI |

## 6. Your controls: export and deletion

* **Export all my data** — one JSON file containing every table (except
  binary photos), shared via the Android share sheet to a destination you
  choose.
* **CSV exports** — per dataset (food log, water, daily activity, workout
  sets, runs, habits, mood). Journal entries are exported **only** if you
  explicitly select them.
* **Delete** — separately for journal, mood, progress photos (files and
  records), AI conversations & memory & activity log, nutrition logs (food and
  water), or **everything** (resets the profile to example targets). Each
  deletion requires typing `DELETE`.
* **Connected services keep their own data.** Deleting data in Athlete OS
  does not delete it from Strava, Hevy, Google or Health Connect. Revoke
  access at:
  * Strava — Settings → My Apps
  * Hevy — Settings → Developer (API key)
  * Google — myaccount.google.com → Security → Third-party connections
  * Health Connect — Android Settings → Health Connect → App permissions

## 7. Security measures

* No AI provider, Strava or Google client secrets are shipped in the APK; all
  privileged calls go through the backend.
* Tokens and keys are held in secure storage; error messages and logs are
  passed through secret redaction before being stored or shown.
* Backend tables use row-level security scoped to the signed-in user.
* AI tool actions that change data require confirmation and are recorded in
  an audit log with idempotency keys.
* Target and goal changes are never silent: they require confirmation and are
  written to goal history.

## 8. What we never do

* No advertising, no selling or sharing of personal data.
* **No analytics or crash reporting that includes health data.**
* No uploading of progress photos.
* No sending of Strava data, journal text, health data or meal photos to AI
  without the rules and consents above.
* No extreme weight-cutting, dehydration or diuretic advice — the coach and
  the competition-prep tools explicitly avoid it and point you to qualified
  professionals.
