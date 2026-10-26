# Architecture

## Goals that shaped the design

1. **Local-first.** The phone is the source of truth. Logging food, water, habits, mood and
   journal works fully offline. A backend is optional and only required for AI and for OAuth
   flows that need a client secret (Strava).
2. **Honest data.** Every metric carries provenance (source, timestamp, estimate flag). Nothing is
   fabricated; unavailable data is shown as unavailable.
3. **Deterministic numbers, AI for interpretation.** Totals, remaining targets, countdowns,
   streaks and analytics are plain, unit-tested Dart. The AI agent calls tools that return those
   numbers; it never computes them itself.
4. **No secrets in the APK.** Provider API keys and OAuth client secrets live on the server.
5. **Replaceable integrations.** Every external service sits behind an interface, so the app keeps
   working when one is unavailable or not configured.

## High-level diagram

```
┌──────────────────────────── Flutter app (Android first) ─────────────────────────────┐
│ presentation/  Screens & widgets (Material 3, dark-first design system in core/)      │
│ application/   Riverpod providers / notifiers / services (sync, notifications, agent) │
│ domain/        Pure Dart models + deterministic calculations (unit-tested)            │
│ data/          Repositories over Drift + API clients behind interfaces                │
│                                                                                       │
│ Drift (SQLite) ── single source of truth on device, soft deletes, UTC + localDate     │
│ flutter_secure_storage ── user-owned credentials (Hevy key, Strava access token)       │
└───────┬─────────────┬───────────────┬──────────────┬──────────────┬───────────────────┘
        │             │               │              │              │
 Health Connect   Hevy API      Google Calendar   Open Food      Supabase (optional)
 (Samsung Health  (api-key)     (google_sign_in   Facts / USDA   ├─ Auth (JWT)
  + Galaxy Watch)               + googleapis)                    ├─ Postgres + RLS (sync)
                                                                 ├─ Edge fn ai-chat ──► Anthropic /
                                                                 │   (keys, rotation,      OpenAI /
                                                                 │    budget, fallback)    Gemini
                                                                 └─ Edge fn strava-oauth ─► Strava
```

## Project layout

```
lib/
  app/            app widget, router (GoRouter StatefulShellRoute), HUD dock shell, boot sequence,
                  bootstrap (parallel, time-boxed hooks), provider overrides (contract wiring),
                  adapters (AI reply drafter), day-change provider
  core/           JARVIS HUD design system (tokens, fonts, shaders, motion, haptics, components),
                  time/clock, formatting, ids, redaction,
                  provenance, env config, shared contracts (CalendarReader), free-slot finder
  data/           Drift schema (tables.dart), database, shared repositories, providers
  features/
    today/        Today dashboard + deterministic daily summary
    nutrition/    food database, logging, recipes, hydration, Open Food Facts/USDA clients
    health/       Health Connect gateway, sync, steps coach, health overview & status
    train/        strength analytics, running analytics, workout/activity detail
    integrations/ Hevy, Strava, Google Calendar clients + Integrations hub
    life/         habits, mood, journal, notifications engine
    planning/     competition prep, planner/reviews, reports, settings, profile, privacy
    coach/        JARVIS AI agent: tool registry + routing, executor, agent loop, voice (STT/TTS), chat UI
    assistant/    personal messaging assistant: notification capture, policy engine, drafts, kill switch
    onboarding/   JARVIS calibration, nutrition calculator, training program, daily routine, meal ideas
    surfaces/     home-screen widget, launcher shortcuts, allowlisted deep links, Quick Settings tile
    devgallery/   HUD component gallery (debug builds only)
supabase/         Postgres migrations (RLS, pg_cron housekeeping) + Edge Functions (ai-chat, ai-status,
                  strava-oauth); live project `athlete-os` (ap-south-1)
android/          Kotlin: notification listener + reply transport, foreground assistant service,
                  share intake, home widget, QS tile, Health Connect settings channel
test/             unit, repository and widget tests mirroring lib/
docs/             this documentation
```

Each feature folder follows `domain/ → data/ → application/ → presentation/`, owns its
`routes.dart` (merged by `app/router.dart`) and a `bootstrap.dart` start-up hook. Features do
not import each other's internals; shared needs go through `core/contracts` or the database.

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| State management | Riverpod 3, hand-written providers | Testable overrides (clock, DB), no codegen churn |
| Navigation | GoRouter `StatefulShellRoute.indexedStack` | Five persistent tabs keep their stacks; deep links like `/coach?prompt=` |
| Local storage | Drift (SQLite) | Typed queries, reactive streams, migrations, in-memory DB for tests |
| Models | Drift data classes + small hand-written domain classes | Freezed/json_serializable added no value over Drift's generated classes here; fewer build steps |
| IDs | Client UUID v4; UUID v5 from `source:externalId` for imports | Offline creation + idempotent re-imports |
| Time | Store instants in UTC + the logging day as `localDate` | Daily totals don't shift when the phone changes timezone |
| Deletes | Soft delete (`deletedAt`) | Undo, and deletions can be synced |
| Health data | Health Connect via the `health` plugin | Samsung Health syncs into Health Connect; Samsung's own Data SDK is partner-gated |
| Steps dedupe | Health Connect aggregate API | Phone + watch overlap is removed by the platform |
| AI orchestration | Agent loop on the client, model calls via the `ai-chat` Edge Function | Keys stay server-side, tools run against local data, and only minimal tool results leave the phone (with consent) |
| AI vendors | Provider-neutral adapters (Anthropic, OpenAI, Gemini) on the server | No lock-in; tool-calling differences normalised in one place |
| Strava + AI | Strava data is excluded from every AI tool | Strava API Policy §5.3 (effective 2026-06-01) forbids AI use of Strava data |
| Notifications | `flutter_local_notifications` zoned schedules | No server needed for reminders; honest about Doze/battery limits |

## Data provenance

`core/domain/provenance.dart` defines `DataOrigin` (Health Connect, Samsung Health, Manual,
Hevy, Strava, Google Calendar, Open Food Facts, USDA, AI estimate, Calculated) and `Sourced<T>`.
UI shows it with `SourceBadge` ("Health Connect · 12 min ago", "AI estimate"). Food entries store
`verification` (`verified_label`, `database`, `user_entered`, `estimate`); AI estimates must be
confirmed before they are saved.

## Error handling & logging

- `redactSecrets()` scrubs keys/tokens from any error before it is stored or displayed.
- Integration failures are written to `integration_connections.last_error` (redacted) and shown
  on the Integrations screen; the rest of the app continues.
- Bootstrap hooks are time-boxed and can't crash start-up.
- Health, journal and mood content is never logged.

## Testing strategy

See `docs/TESTING.md`. Pure domain logic is unit-tested; repositories run against an in-memory
Drift database; API clients are tested with `http/testing.dart` mocks; screens have widget tests
for empty/unavailable states and real-data rendering.

## Native Android layer

The messaging assistant and home-screen surfaces need platform APIs Flutter does not expose:
`NotificationListenerService` (capture + RemoteInput reply), a `specialUse` foreground service,
`AppWidgetProvider`, `TileService` and launcher shortcuts. They live in
`android/app/src/main/kotlin/com/athleteos/athlete_os/{assistant,surfaces}` and talk to Dart over
MethodChannels/EventChannels. When the Flutter engine is not running, native code queues events
(captured notifications, widget/tile water taps) to small files that Dart drains idempotently on
the next start.

## Build flavours of the experience

- **Debug** builds run JIT and stutter; use **release** (`flutter build apk --release`) on device.
  Release signing reads `android/key.properties` (git-ignored) pointing at a keystore kept outside
  the repo; R8 shrinking is disabled because several plugins rely on reflection.
- Client config (public IDs only) is compiled in with `--dart-define-from-file=config/dev.json`.
