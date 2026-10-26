# Athlete OS

A private, Android-first personal operating system for physique, fitness, nutrition, health habits,
productivity and well-being â€” with a tool-using AI coach and a personal messaging assistant.
Built with Flutter, local-first (Drift/SQLite), with an optional Supabase backend for AI and OAuth.

> Core principle: collect data automatically where possible, make manual entry effortless where
> necessary, turn data into actionable insights, and keep the user in control.

## Features

| Area | What you get |
|---|---|
| **Today** | Competition countdown hero, deterministic smart summary (only states backed by data), steps/distance/active minutes, latest workout, weekly running, sleep & HR with source + timestamp, calories/macros/water vs targets, calendar, habits, mood/journal status, top priorities |
| **Nutrition** | Open Food Facts search & barcode scan, USDA (optional), custom foods, recipes, saved meals, recents/favorites, copy meals, quick add, serving or gram entry, natural-language parsing, AI estimates clearly flagged and confirmed before saving, history charts, adherence, CSV export |
| **Hydration** | One-tap logging, progress ring, history, configurable goal, reminders with a "Log 250 ml" notification action |
| **Health** | Health Connect (Samsung Health / Galaxy Watch via HC): steps (deduped aggregate), distance, exercise, heart rate, sleep, weight; permission-aware; source & freshness labels; manual fallback; steps coach with remaining steps and per-waking-hour pace |
| **Train** | Hevy API sync (incremental via events), manual logging, CSV import, e1RM/PRs/volume/stall detection, weekly volume by mapped muscle group; Strava sync, running dashboard, 5K goal progress, rule-based post-run review |
| **AI Coach** | Provider-neutral (Anthropic / OpenAI / Gemini) tool-using agent; typed tools with validation, consent gating, write confirmation, audit log, idempotency; memory you approve; recommendations history; budgets, key rotation and fallback on the server |
| **Life** | Habits with honest streaks (skips are neutral), mood check-ins & trends, private journal, correlations shown as observations, reminders engine with quiet hours and calendar awareness |
| **Planning** | Competition prep (timezone-correct countdown, milestones, checklist, progress photos stored only on device), daily planner with free-slot suggestions, end-of-day & weekly review, weekly/monthly reports, CSV export |
| **Assistant** | Notification-based message triage for apps you allow, drafts in your tone, approval before send, code-enforced safety rules, kill switch, content-free audit log, daily briefing |
| **Privacy** | Local-first, consent toggles for AI use of health/journal/photos, export everything, per-category delete, secrets never in the APK |

Nothing is ever fabricated: every metric shows where it came from and when, and unavailable
data is labelled as unavailable.

## Quick start

```powershell
# Toolchain: see docs/SETUP.md (Flutter 3.47.8, JDK 21, Android SDK 36)
flutter pub get
copy config\dev.example.json config\dev.json          # optional: backend / OAuth client IDs
flutter run --dart-define-from-file=config/dev.json   # or plain `flutter run` for local-only mode
```

Build an installable APK:

```powershell
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | Environment installation, device setup, emulator notes |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, decisions, data provenance |
| [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) | Every provider, credentials, limits, policy constraints |
| [docs/DATABASE.md](docs/DATABASE.md) | Local Drift schema, migrations, Supabase schema & RLS |
| [docs/AI_AGENT.md](docs/AI_AGENT.md) | Providers, tools, memory, budgets, retries, rotation, security |
| [docs/MESSAGING_ASSISTANT.md](docs/MESSAGING_ASSISTANT.md) | Messaging capability matrix, modes, safety rules |
| [docs/PERMISSIONS.md](docs/PERMISSIONS.md) | Every Android permission and how to revoke it |
| [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md) | Reminder kinds, scheduling, Android battery limits |
| [docs/PRIVACY.md](docs/PRIVACY.md) | Data collected, flows, retention, deletion |
| [docs/TESTING.md](docs/TESTING.md) | Test commands and actual results |

## Third-party costs

Free: Health Connect, Open Food Facts, USDA FDC, Google Calendar API, Strava API, Supabase free
tier. Paid: **Hevy Pro** (required for its API) and **AI provider usage** (per token, capped by
`AI_MONTHLY_BUDGET_USD` on the server). Nothing else incurs cost.

## Attributions

Food data from [Open Food Facts](https://world.openfoodfacts.org) (ODbL). Activity data
"Powered by Strava". Nutrient data from USDA FoodData Central (public domain).

## License

MIT for the source code — see [LICENSE](LICENSE). Third-party data, fonts and integrations keep their own terms — see [CREDITS.md](CREDITS.md).

