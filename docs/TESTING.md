# Testing

## Commands

```powershell
dart format lib test          # formatting (CI expects 0 changed files)
flutter analyze               # static analysis (lints in analysis_options.yaml)
flutter test                  # all unit + widget tests (in-memory Drift DB)
flutter test test/features/<feature>      # one feature
npx -y deno@2.9.6 test supabase/functions # edge-function unit tests
flutter build apk --debug --target-platform android-arm64
```

Layout tests that check overflows must load the real fonts first (`test/helpers/real_fonts.dart`,
`setUpAll(loadRealFonts)`): the default test font is much wider than Inter and reports false overflows.

Visual QA: `flutter test tool/qa_shots_test.dart --dart-define=SHOT_DIR=build/shots/qa` renders the
first-run journey (all 18 onboarding steps → Engage → Today, then every tab freshly calibrated); the
per-feature `tool/r_*_shots_test.dart` suites take the same `SHOT_DIR`.

Test helpers live in `test/helpers/test_app.dart`:
`newTestDb()` (in-memory Drift), `testOverrides(db, now:)` (fixed clock), `testHarness(widget, …)`.
Widget tests that use Drift streams finish with
`await tester.pumpWidget(const SizedBox()); await tester.pump(const Duration(milliseconds: 10));`
so pending stream timers settle.

## What is covered

| Area | Examples |
|---|---|
| Core | Local-date arithmetic across month/year/leap boundaries, free-slot finder, secret redaction |
| Database | Fresh create + seed, **v1 → v2 migration** preserving data |
| Nutrition | Serving/gram scaling, day totals, remaining/"over by", adherence, weekly averages over logged days, recipe per-serving math, soft delete, copy meals, Open Food Facts/USDA parsing (complete, partial, not-found, 429/5xx retry, offline, rate limit), natural-language parser |
| Hydration | Totals, remaining, undo |
| Health | Remaining steps = max(0, goal − steps), %, per-waking-hour pace, behind-pace, sleep-night assignment across midnight, exercise overlap merge, sync idempotency (run twice → same rows), revoked permissions, manual vs Health Connect precedence |
| Train | Hevy paging/events/401/429, import idempotency, CSV parser, e1RM/PRs/warm-ups excluded, stall detection, Strava mapping, 7-day purge, Strava↔HC de-duplication, splits CV, best-5K from splits, conservative next-run suggestions |
| Life | Honest streaks (skips neutral), weekly targets, auto rules, reminder scheduler (quiet hours overnight, DST, caps, busy intervals), crisis-keyword detector without gym false positives |
| Planning / Today | Competition countdown across timezones/DST/leap/past dates, deterministic daily summary (only-available-data rule), report builder, task carry-over, profile diff + goal history |
| AI coach | Tool argument validation, consent gating, write confirmation, idempotent replay, audit log, every read tool against seeded data, **Strava rows never appear in any tool output**, agent loop (tool call → result → answer; rejection; max rounds), prompt contains no bulk history |
| Assistant | Notification access only after explanation, disabled apps ignored, Draft mode never sends, auto-reply rules enforced in code (WhatsApp block, sensitive flags, caps, quiet hours, confidence, identity, groups), duplicate events → one draft, kill switch stops automation, no content/credentials in logs |
| App-wide UX (QA pass) | `test/app/route_coverage_test.dart`: every `AppPaths` route (read from `paths.dart`) builds with real fonts in empty, seeded and 1.3× text states without exceptions or overflows, and no enabled button is unreachable by TalkBack. `navigation_links_test.dart`: every literal in-app location in `lib/`, launcher shortcut and deep-link target resolves to a registered route, and every query parameter is read by that route. `accessibility_test.dart`: tab roots meet Android tap-target, labelled-target and text-contrast guidelines. `coach_listen_link_test.dart`: `/coach?listen=1` explains, asks and listens. |
| Backend (Deno) | Provider adapters (request/response + tool calls), error classification, backoff with Retry-After, circuit breaker, budget thresholds, redaction |

## Recorded results

| Date (2026-10-25) | Scope | Result |
|---|---|---|
| 20:30 | Foundation | analyze: no issues · tests: 6/6 passed |
| 22:09 | 6 feature slices merged | analyze: no issues (271 files) · tests: **412/412 passed** |
| 23:58 | + messaging assistant + wiring fixes | analyze: no issues (294 files) · tests: **465/465 passed** |
| — | Backend Deno suite (AI agent branch) | 109/109 passed (`deno test`), `deno check` clean |
| 2026-10-26 | QA hardening pass (engineering) | analyze: no issues · tests: **698/698 passed** (incl. golden-path workflows in `test/golden_path/`) · Deno: 142/142 |
| 2026-10-26 06:00 | **Final**: all features + JARVIS redesign + UX/engineering QA + residual fixes | format clean · analyze: no issues · tests: **841/841 passed** (+2 readiness regression) · Deno: **150/150** · release APK (arm64, 70.6 MB, signed) built, installed on OPPO CPH2251, calibration completed on device |
| 22:35 | Debug APK (arm64) | built and installed on OPPO CPH2251; launched to Today screen |

Results are appended as later phases land. Device-only behaviour (Health Connect permission
dialogs, notification listener, reply actions, exact alarms under ColorOS) still needs on-device
verification; see the checklist in `docs/SETUP.md`.
