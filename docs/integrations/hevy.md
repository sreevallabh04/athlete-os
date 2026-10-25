# Hevy integration

Athlete OS imports strength workouts from [Hevy](https://www.hevyapp.com) using
Hevy's official public API. The integration is **read-only**: the app never
creates, edits or deletes anything in Hevy.

## Requirements

- A **Hevy Pro** subscription (the public API is a Pro feature).
- An API key from <https://hevy.com/settings?developer>.

## Setup

1. Sign in at <https://hevy.com/settings?developer> and generate an API key.
2. In Athlete OS open **Integrations -> Hevy** and paste the key.
3. Tap **Test connection** (calls `GET /v1/user/info`). On success the initial
   import starts.

### How the key is stored

- Stored only in Android encrypted secure storage (`flutter_secure_storage`,
  backed by the Android Keystore). It is not written to the database, logs,
  backups or crash reports.
- Never logged; redacted from any error message or exception text shown in the UI.
- Never sent anywhere except `api.hevyapp.com` in the `api-key` header.

## API reference

- Docs: <https://api.hevyapp.com/docs/> (version 0.0.1 at time of writing; the
  API is young and may change without notice).
- Base URL: `https://api.hevyapp.com`
- Auth header: `api-key: <your key>`

| Endpoint | Purpose |
| --- | --- |
| `GET /v1/user/info` | Test connection / show account name |
| `GET /v1/workouts?page=&pageSize=` | Initial full import (`pageSize` max 10) |
| `GET /v1/workouts/events?page=&pageSize=&since=` | Incremental sync |
| `GET /v1/exercise_templates?page=&pageSize=` | Exercise metadata (`pageSize` max 100), fetched at most weekly |
| `GET /v1/workouts/count` | Optional: progress indicator for the initial import |

## Sync model

- **Initial import**: pages through `/v1/workouts` until an empty page.
- **Incremental**: `/v1/workouts/events?since=<cursor>`:
  - `updated` event -> upsert the workout and **replace** its exercises and sets
    inside a single database transaction (no partial workouts).
  - `deleted` event -> soft-delete the workout (hidden from history and analytics).
- **Cursor**: the latest processed `updated_at` / `deleted_at` is stored in
  `IntegrationConnections.cursor`. It is advanced only after the page commits.
- **Idempotency**: local ids are `stableId('hevy', <hevy id>)`, so re-running a
  sync or re-importing never creates duplicates.
- **Exercise templates**: refreshed at most once a week. `primary_muscle_group`
  drives muscle-group mapping for analytics.
- **When it runs**: on manual **Sync now** and on app start (debounced). It is
  not scheduled at fixed times such as :00, as Hevy's docs request.

## Limits and errors

- Rate limits are undocumented. The client retries `429` and `5xx` with
  exponential backoff plus jitter, honouring `Retry-After`, max 4 attempts.
- Request timeout: 20 s.
- `401` -> shown as **"Invalid API key"**; sync stops until a new key is saved.
- `403` usually means Hevy Pro has lapsed.

## Disconnect

**Integrations -> Hevy -> Disconnect** deletes the API key from secure storage,
then asks whether to:

- **Keep imported workouts** (they stay as history, no further sync), or
- **Delete imported workouts** (all rows with source `hevy` are removed).

## CSV fallback (no Hevy Pro)

1. In the Hevy app: **Settings -> Export data -> CSV**.
2. Open the CSV, copy its text, and paste it into **Train -> Import CSV**.
   (A file picker needs the `file_picker` package; it has been requested.)

Expected columns (header names matter, order does not):

```
title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,
set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe
```

- Rows are grouped into workouts by `title` + `start_time`.
- Idempotent: workout ids are `stableId('csv', title + start_time)`, so pasting
  the same export twice does not duplicate anything.
- Unknown columns are ignored; missing optional columns are treated as empty.

## Manual logging

Workouts can also be logged directly in the app (source `manual`). They are
treated exactly like imported workouts in analytics.

## Privacy

- All workout data stays on the device.
- Hevy-derived data may be used by the AI coach **only** as permitted by the
  app's AI consent settings. Hevy's terms have no AI restriction comparable to
  Strava's.

## Analytics notes

- **Estimated 1RM** uses Epley (`weight * (1 + reps / 30)`), only for sets of
  1-12 reps, and excludes warm-up sets.
- **Sets per muscle group** count only exercises with a known muscle mapping;
  unmapped custom exercises are excluded rather than guessed.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Invalid API key" | Regenerate the key at hevy.com/settings?developer and paste again. |
| Test connection fails with 403 | Check that Hevy Pro is active. |
| Workouts missing after editing in Hevy | Tap **Sync now**; edits arrive as `updated` events. |
| Deleted workout still visible | Sync again; deletions arrive as `deleted` events. |
| Repeated "rate limited" | Wait a few minutes; the app already backs off automatically. |
| CSV import says "missing columns" | Make sure the header row was included in the paste. |
