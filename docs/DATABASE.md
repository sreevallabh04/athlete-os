# Database

Athlete OS is **local-first**: the source of truth is an on-device SQLite
database managed by [Drift](https://drift.simonbinder.eu/)
(`lib/data/db/tables.dart`, generated `database.g.dart`). An optional Supabase
Postgres schema (`supabase/migrations/`) mirrors it for backup/sync and holds
the AI backend's server-only tables.

## Conventions (local and server)

* **IDs** — client-generated UUID v4 strings (`newId()`), so rows can be
  created offline and synced idempotently. Imports use deterministic v5 ids
  (`stableId(namespace, externalId)`); AI tool writes derive ids from the tool
  idempotency key.
* **Time** — instants are stored in UTC. `localDate` (`YYYY-MM-DD`) records the
  user's calendar day at logging time, so daily totals never shift when the
  device timezone changes; entries also keep `tzName`. Competitions store
  `eventDate` + IANA `tzName` and count days in the event's timezone.
* **Soft delete** — `deletedAt` on user-editable tables; every query and every
  AI tool filters `deleted_at IS NULL`.
* **Imports** — `source` + `externalId` unique together (re-imports are
  upserts), original payload in `rawJson`. Health samples are unique on
  `(origin, type, externalId)`.
* **Provenance** — every metric keeps its source (`source`, `origin`,
  `sourceApp`, `verification`) so the UI and AI can label measured, imported,
  manual and estimated data. Food log entries are nutrient **snapshots**.
* **Strava** — `cardio_activities.source = 'strava'` rows are never sent to AI
  (Strava API Agreement §5.3) and must be refreshed/purged within 7 days.

## Local tables

| Area | Tables | Purpose |
|---|---|---|
| Profile | `user_profiles` (single row id=1), `goal_history`, `app_settings` (JSON key/value: theme, consents, `ai.*` prefs), `health_restrictions` | Targets, diet, schedule window, coaching style; audit of every target change; injuries. |
| Nutrition | `foods`, `food_log_entries`, `recipes`, `recipe_ingredients`, `saved_meals`, `saved_meal_items` | Food definitions (per serving) and logged snapshots with `verification` (verified_label / database / user_entered / estimate). |
| Hydration | `water_logs` | ml per log, source manual / notification / ai. |
| Health | `health_samples`, `daily_health_summaries` | Raw samples (HR, weight, sleep, sessions) and de-duplicated daily aggregates (steps, distance, active minutes, sleep) per origin. |
| Training | `workouts`, `workout_exercises`, `workout_sets`, `cardio_activities` | Hevy/manual strength sessions; runs/rides from Strava, Health Connect or manual. |
| Well-being | `mood_entries`, `journal_entries`, `habits`, `habit_completions`, `tasks` | Mood 1–5, journal, habits with schedules/streaks, daily priorities. |
| Planning | `calendar_event_refs`, `competitions`, `competition_milestones`, `progress_photos` | App-created calendar events, competition prep, on-device photos. |
| AI | `ai_conversations`, `ai_messages`, `ai_tool_actions`, `ai_memories`, `ai_recommendations` | Chat history (normalised content blocks + provider/model/tokens), tool audit log (unique `idempotencyKey`), user-approved memory, recommendation responses. |
| System | `integration_connections`, `sync_queue`, `notification_prefs`, `reports` | Integration status/cursors, offline sync queue (unique idempotency key), notification config, generated reports. |

### Indexes (created in `onCreate`)

`food_log_entries(local_date)`, `foods(barcode)`, `foods(name)`,
`water_logs(local_date)`, `health_samples(type, local_date)`,
`workouts(start_at)`, `cardio_activities(start_at)`, `mood_entries(local_date)`,
`journal_entries(local_date)`, `habit_completions(local_date)`,
`tasks(local_date)`, `sync_queue(next_attempt_at)`,
`ai_messages(conversation_id, created_at)`. Unique keys come from the table
definitions (e.g. `workouts(source, external_id)`,
`habit_completions(habit_id, local_date)`, `ai_tool_actions(idempotency_key)`).

### Migration strategy

`AppDatabase.schemaVersion` (currently **2**) + `MigrationStrategy`:

* `onCreate` creates all tables, the indexes above and seeds the profile row.
* `beforeOpen` enables `PRAGMA foreign_keys = ON`.
* Every connection runs `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout = 5000`
  (`AppDatabase.configureConnection`): the notification-action isolate opens its
  own connection to the same file, so writers wait for each other instead of
  failing with "database is locked".
* To change the schema: edit `tables.dart`, bump `schemaVersion`, add an
  `onUpgrade` step (`if (from < 2) await m.addColumn(...)`), regenerate with
  `dart run build_runner build`, and export a schema snapshot
  (`dart run drift_dev schema dump`) so step-by-step migrations can be tested.
  Never edit a released migration; add a new step.
* Mirror every change in a **new** Supabase migration file.

## Backend (Supabase Postgres)

`supabase/migrations/20261025000000_init.sql` (Strava tokens live in
`20261025000100_strava_tokens.sql`, owned by the Strava integration):

* Every local table has a snake_case twin with
  `user_id uuid not null references auth.users on delete cascade`, the same
  text UUID primary keys (keyed tables use user-scoped keys:
  `user_profiles(user_id)`, `app_settings(user_id, key)`,
  `daily_health_summaries(user_id, local_date, type, origin)`,
  `integration_connections(user_id, provider)`,
  `notification_prefs(user_id, kind)`), `created_at/updated_at/deleted_at`,
  calendar fields as `date`, instants as `timestamptz`.
* Children reference parents with composite FKs `(user_id, parent_id)` so a
  row can never point at another user's data.
* CHECK constraints for enums and ranges (meal type, mood/energy/stress 1–5,
  water 1–5000 ml, cardio source, statuses), unique
  `(user_id, source, external_id)` for imports and
  `(user_id, idempotency_key)` for `ai_tool_actions`/`sync_queue`.
* Shared `set_updated_at()` trigger on every table with `updated_at`.
* **RLS enabled on all tables**; user tables have select/insert/update/delete
  policies `user_id = auth.uid()`.
* `user_settings` — AI preferences (primary_provider, model,
  fallback_providers[], max_tokens 256–16000, timeout_ms 5000–120000,
  monthly_budget_usd) with user RLS.
* **Server-only** (RLS on, no client policies, no client grants; edge
  functions use the service role): `ai_usage` (per request: provider, model,
  credential alias, tokens, cost, status, latency; `request_id` unique),
  `ai_credential_health` (provider, alias, status
  ok/rate_limited/quota_exhausted/invalid/disabled, cooldown, failures,
  redacted last error), `ai_circuit_state` (per-provider breaker),
  `ai_response_cache` (idempotent retries, 24 h TTL), `api_rate_limits`
  (fixed-window counters).
* Functions (service role only): `increment_rate_limit`, `ai_month_spend`,
  `ai_global_month_spend`, `ai_month_usage`, `purge_ai_response_cache`,
  `purge_api_rate_limits`.

## Initialising a new Supabase project

```bash
npm i -g supabase            # or use your package manager / scoop
supabase login
supabase link --project-ref <ref>
supabase db push             # applies every file in supabase/migrations
```

Then: enable Anonymous and/or Email OTP auth providers; schedule the purge
functions hourly (Database → Cron, or
`select cron.schedule('ai-purge', '0 * * * *', $$select purge_ai_response_cache(); select purge_api_rate_limits();$$);`);
set function secrets and deploy functions (see `docs/AI_AGENT.md`); copy the
project URL and anon key to `config/dev.json`.

Local development: `supabase start` runs Postgres + Auth in Docker and applies
migrations; `supabase db reset` re-applies them from scratch.
