# AI Coach — architecture & operations

The coach is a tool-using agent. The **agent loop runs on the device**; model
calls go through a **Supabase Edge Function** that holds the provider keys.
Health data stays in the local Drift database and only the minimal tool results
a question needs are sent, and only after the user consents.

```
 ┌──────────────────────── Android app (Flutter) ────────────────────────┐
 │ CoachScreen ─▶ CoachController (Notifier, agent loop, ≤6 tool rounds) │
 │                  │  system prompt (date/tz, profile, ≤20 memories)    │
 │                  │  routed tools (≤8 of 23)       ▲ tool_result blocks│
 │                  ▼                                │                    │
 │        AiBackendClient ──────────────┐   ToolExecutor ── Drift (local) │
 │   (Supabase impl / Unconfigured)     │   validate → consent → confirm  │
 │                                      │   → run → audit (ai_tool_actions)│
 └──────────────────────────────────────┼─────────────────────────────────┘
                     HTTPS + user JWT   │  {system, messages, tools, request_id, prefs}
 ┌──────────────────────────────────────▼─── Supabase Edge (Deno) ─────────┐
 │ ai-chat: auth.getUser → validate (size limits) → idempotency cache      │
 │   → rate limit (30/min) → budget (user + global) → provider selection   │
 │   → resilience (retry/backoff, key rotation, circuit breaker, fallback) │
 │   → adapter (gemini | groq | anthropic | openai) → normalised response  │
 │   → ai_usage + ai_response_cache                                        │
 │ ai-status: providers/aliases/health (no key values), usage, test calls  │
 └─────────────────────────────────────────────────────────────────────────┘
```

## Request flow

1. User sends a message → persisted to `ai_messages` (role `user`).
2. `CoachController` builds the request: system prompt, the last ≤40 messages
   within a **12 000-char history budget** (never starting on an orphaned
   tool result; large tool results of *earlier* turns are replaced by a
   stub), the **routed tool subset** (≤ 8 schemas, see *Speed* below),
   preferences, and a fresh `request_id`. The whole call has a client-side
   ceiling of `min(timeout_ms, 45 s) + 15 s`.
3. `ai-chat` returns `{content:[text|tool_call|opaque], stop_reason, usage,
   provider, model, request_id, meta}`. The assistant turn is persisted with
   provider/model/token counts.
4. For each `tool_call`, `ToolExecutor`:
   * replays the stored result if `conversationId:toolCallId` already finished;
   * validates arguments against the schema (unknown properties rejected);
   * checks consent (`ai_health_consent` / `ai_journal_consent`) — if missing
     the UI shows a **consent card**;
   * for write tools inserts a `pending_confirmation` audit row and the UI shows
     a **confirmation card** (Approve / Edit / Reject);
   * runs the handler (20 s timeout), audits the result (`ok`, `confirmed`,
     `error`, `rejected`). Errors become `is_error` results with redacted text.
5. Results are sent back as a user turn of `tool_result` blocks; loop until
   the model answers with text, at most **6 tool rounds** and a 3-minute turn
   budget (time spent on cards excluded). Cancel closes unanswered calls.
6. Errors show a red *link fault* card; **Retry re-sends the same
   `request_id`**, so the server returns its cached response (24 h) instead
   of paying twice. For timeouts/upstream faults the card also offers
   **Try Groq (fast)**: the same turn re-sent with a new request id and
   `primary_provider: groq` (possible because routed requests fit Groq's
   free-tier 8 K tokens/minute).

When the build has no `SUPABASE_URL`/`SUPABASE_ANON_KEY`, or the user isn't
signed in, `UnconfiguredAiBackend`/`AiBackendState.signedOut` is used: the coach
shows an honest *AI backend not configured* card and `OFFLINE · NO BACKEND`
status, **never fabricates an answer**, and still runs the local briefings.

## Speed: tool routing and request budget

Sending all 23 tool schemas cost ≈ 4 K tokens per call before any history,
so a few turns pushed requests past Groq's free-tier 8 K tokens/minute (413
→ no fallback) and slowed Gemini. `lib/features/coach/agent/tool_router.dart`
now picks tools deterministically per user message:

* **Core set, always sent:** `get_today_dashboard`, `get_profile_and_goals`.
* **Categories by keyword** (word-start stems, short words must match
  whole words): nutrition, hydration, activity, training, schedule, life,
  competition, review, memory. Matched categories are merged round-robin
  (most hits first) so every category keeps its primary tool.
* **Follow-ups** without keywords ("and yesterday?") reuse the tools the
  conversation called most recently; otherwise a general daily-overview set.
* **Cap: 8 tools.**
* **Missing tool:** if the model calls a registered tool it was not given,
  the call still runs locally and the rest of the turn is widened to the
  full catalogue; an unknown name becomes a normal `is_error` result.
* The system prompt was tightened (same safety rules, ≈ 600 tokens incl.
  the JARVIS persona) and asks for a one-sentence lead so answers can be
  read aloud.

Measured by `test/features/coach/tool_router_test.dart` (estimate = UTF-8
bytes ÷ 3.3, conservative for JSON; printed by the test):

| Request ("How much protein do I have left today?") | System | Tools | History | Total |
|---|---|---|---|---|
| Before: 23 tools + 5 earlier turns, uncompacted | 594 | 3 975 | 4 773 | **≈ 9 340** |
| After: 6 routed tools + compacted history | 594 | 1 333 | 965 | **≈ 2 890** (−69 %) |
| After: first message of a session | 594 | 1 333 | 29 | **≈ 1 960** |

The test asserts ≤ 6 000 tokens for a typical multi-turn request and
≤ 3 000 for a first message. `CoachState.lastRequest` keeps the estimate of
the latest call for debugging.

### Perceived latency

Gemini 3.x can take 20–25 s on a first tool call. The Coach makes the wait
intentional: the orb switches to *thinking* the moment you send (before any
IO), a live `Consulting Gemini · 00:07` subsystem line counts up, tool calls
appear as named subsystems ("Scanning nutrition log · Oct 26", "Reading
Health Connect"), and after 8 s a line explains that deep reasoning is in
progress. Answers then reveal word by word (tap to skip).

## Coach UI (JARVIS)

`lib/features/coach/presentation/coach_screen.dart`:

* **Status line** (`deriveCoachLink`, unit-tested): `OFFLINE · NO BACKEND`,
  `STANDBY · SIGNING IN`, `LINKING`, `ONLINE · GEMINI · 2.4 S` (provider of
  the latest answer + latency), `FALLBACK · GROQ` (`meta.fallback_used`, or
  ai-status shows the primary unhealthy), `DEGRADED · LINK TIMEOUT` after a
  fault. While voice is active it shows `LISTENING…` / `SPEAKING…`.
* **Core orb** (`JarvisCore` = shared `JarvisOrb` + halo): idle reticle,
  listening ring driven by the real mic level, thinking scanner, speaking
  arc + per-word ripples. Large and centred on an empty session; glides
  into the header once a session starts. Tap = talk / stop speaking,
  hold = push-to-talk.
* **Transcript**: user lines as right-aligned glass; JARVIS replies on a
  luminous rule with word-by-word reveal, source tags and a read-aloud
  button; consecutive tool calls grouped as a subsystem trace; redesigned
  authorisation (Approve / Edit / Reject) and privacy (Allow / Not now)
  cards with haptics; red link-fault card with Retry / Try Groq / Settings.
* **Quick commands** (`quickCommands`, deterministic, unit-tested): time of
  day picks *Brief me* (04–16 h) or *Review my day*; data-aware entries
  appear only when the data exists (protein target, steps below goal, water
  below goal, a planned session, pending drafts, an upcoming competition).
* **History** slides in from the left (swipe a session to delete).
* **Systems** sheet: Voice, Coach memory, AI activity log, AI settings.
* Haptics on every state change (consulting/tools/briefing → selection,
  approval card → medium, answer → success, fault → warning).

## Briefings ("Brief me", "Review my day")

`lib/features/coach/agent/briefing.dart`. Deterministic text from local
data — the assistant's `BriefingService` lines (steps vs goal, calories,
protein, water, calendar, drafts awaiting approval, unanswered messages,
habits), today's planned session (`plannedSessionProvider`), the routine's
next blocks, and (evening) tomorrow's session. Unknown data is reported as
unknown, never as zero. Works offline and without AI consent.

When the backend is ready **and** health data may be shared with AI, the
text is rephrased once by `AiTextService.complete` (no tools, 700 tokens,
25 s cap) with a prompt that forbids new facts and requires every number to
be kept; on any failure the deterministic text stays. Briefing rows are
stored with role `briefing`, rendered in a HUD frame with *Local data* /
*AI-polished* tags, and **never sent to a model** (`toWireMessages` skips
non-`user/assistant/tool` roles). Voice shortcuts: saying "Brief me" or
"Review my day" runs them without a model call.

Voice input/output is documented in [VOICE.md](VOICE.md).

### Wire contract (normalised)

Request: `{request_id, conversation_id, system, messages:[{role:user|assistant,
content:[Block]}], tools:[{name, description, input_schema}], preferences:
{primary_provider, model, fallback_providers, max_tokens, timeout_ms,
max_retries, monthly_budget_usd}}`.

Blocks: `text{text}` · `image{media_type,data}` (user; base64 JPEG/PNG/WebP,
≤ 1 MB decoded, ≤ 1 per request, sent only to image-capable providers —
Gemini/Anthropic/OpenAI, never Groq) ·
`tool_call{id,name,arguments,provider_meta?}` (assistant)
· `tool_result{tool_call_id,name,content(JSON string),is_error}` (user) ·
`opaque{provider,data}` (assistant; provider state such as Anthropic thinking
blocks, OpenAI reasoning items — replayed verbatim to the same provider, dropped
for others).

Errors: `{error:{code,message,retry_after_s?}}` with codes `unauthorized` 401,
`invalid_request` 400, `rate_limited` 429, `budget_exceeded` 402,
`no_provider_configured`/`providers_unavailable` 503, `upstream_error` 502,
`timeout` 504, `conflict` 409 (request_id owned by another user), `internal` 500.
The client maps them to friendly, redacted messages; `rate_limited`, `timeout`,
`upstream_error`, `providers_unavailable`, `internal` and network errors are
retryable.

## Providers & adapters

`supabase/functions/_shared/providers/` — pure adapters (request builder,
response parser, error parser) plus `call.ts` for the fetch.

| Provider | Endpoint | Tools / results | Notes |
|---|---|---|---|
| Anthropic | `POST /v1/messages`, `x-api-key`, `anthropic-version: 2023-06-01` | `tools[{name,description,input_schema}]`, `tool_use` ↔ `tool_result` | `tool_choice: auto` only (forced `any`/`tool` → 400 on current models); never sends `temperature/top_p/top_k` or disabled thinking; thinking blocks kept as `opaque` and replayed; optional `output_config.effort` via `AI_ANTHROPIC_EFFORT`. |
| OpenAI | `POST /v1/responses`, Bearer | `tools[{type:function,name,parameters}]`, `function_call` ↔ `function_call_output` | `store:false`, `include:["reasoning.encrypted_content"]`, reasoning items replayed as `opaque`; arguments JSON-parsed (bad JSON → `{}` + raw in provider_meta, client validation rejects). |
| Gemini | `POST /v1beta/models/{m}:generateContent`, `x-goog-api-key` | `functionDeclarations` (schema sanitised), `functionCall` ↔ `functionResponse` | `thoughtSignature` round-tripped through `provider_meta`; calls from other providers get the documented skip-validator placeholder. `image` blocks → `inlineData`. |
| Groq | `POST https://api.groq.com/openai/v1/chat/completions`, Bearer | `tools[{type:"function",function:{name,description,parameters}}]`, `message.tool_calls` ↔ `role:"tool"` messages with `tool_call_id` | OpenAI-compatible Chat Completions; `max_completion_tokens`; `message.reasoning` (gpt-oss) dropped; arguments JSON-parsed (bad JSON → `{}` + `raw_arguments`); usage `prompt_tokens/completion_tokens`; text-only (images never routed here). Errors: 401 → invalid key; 429 → `retry-after` / `x-ratelimit-reset-{tokens,requests}` (daily request limit exhausted → key cooldown until reset); **413 "Request too large" (request > free-tier TPM) → `request_too_large`: no retry, no key/breaker penalty, next provider**; 498/5xx and `tool_use_failed` → transient. |

### Model defaults and how to change them

Defaults are configuration, not code: `AI_DEFAULT_MODEL_ANTHROPIC`
(`claude-sonnet-5-5`), `AI_DEFAULT_MODEL_OPENAI` (`gpt-5.4-mini`),
`AI_DEFAULT_MODEL_GEMINI` (code default `gemini-3.8-flash`; **production secret
`gemini-3.6-flash`**, see below), `AI_DEFAULT_MODEL_GROQ`
(`openai/gpt-oss-120b`).

Model choice (checked 2026-10-25 against ai.google.dev/gemini-api/docs/models
and console.groq.com/docs/models + `GET /models` with our keys):
* **Gemini:** `gemini-3.8-flash` and `gemini-3.6-flash` are both stable Flash
  models with function calling, same price. During go-live 3.8-flash was
  overloaded (repeated `503 UNAVAILABLE "high demand"` and 60 s hangs) while
  3.6-flash answered tool calls in 3–13 s, so production runs 3.6-flash; switch
  back with `supabase secrets set AI_DEFAULT_MODEL_GEMINI=gemini-3.8-flash`.
* **Groq:** `openai/gpt-oss-120b` is a production model with tool use and the
  key can list it (`llama-3.3-70b-versatile` is not available to this key).
  `openai/gpt-oss-20b` is priced/allowlisted and is what "Test connection"
  uses (cheapest). Users may pick a model in
**AI settings**; the server only honours models on the allowlist (price-table
models of that provider + `AI_ALLOWED_MODELS_<PROVIDER>`). To add a model:
add it to `AI_PRICE_TABLE_JSON` (or `DEFAULT_PRICES` in `budget.ts`) and, if
needed, the allowlist env var; redeploy.

Default prices (USD / 1M tokens in/out): claude-sonnet-5-5 2/10,
claude-haiku-5-5 0.10/0.50 (≤100K-token prompts; 0.50/2.50 above),
claude-opus-5-5 4/20, gpt-5.4-mini 0.75/4.50, gemini-3.8-flash and
gemini-3.6-flash 0.75/3.75 (**doubles to 1.50/7.50 on 2027-01-01** — update
`DEFAULT_PRICES` or `AI_PRICE_TABLE_JSON` then), openai/gpt-oss-120b 0.15/0.60,
openai/gpt-oss-20b 0.075/0.30. While the keys are on free tiers the recorded
cost is an upper bound (what it would cost on a paid tier).

## Provider order & secondary-key policy (production)

* `AI_PROVIDER_ORDER=gemini,groq`: **Gemini is primary, Groq is the fallback.**
  The client default `fallback_providers` is `["gemini","groq"]`; users can
  pick a primary in AI settings (only configured providers are used).
* **Exactly one secondary Gemini key** (`GEMINI_API_KEY_SECONDARY`) is
  configured, strictly for **failover** when the primary key is invalid,
  revoked or out of quota (`invalid_credential` / `quota_exhausted`). Keys are
  never rotated for load: transient errors and short rate limits retry the
  same key and then fall back to Groq. We do **not** configure additional
  Gemini keys to multiply free-tier quota — Google's Gemini API terms prohibit
  circumventing rate limits. The other keys in the owner's local `.env`
  (`GEMINI_API_KEY_3`/`_4`) are intentionally not deployed.
* `GROQ_API_KEY_SECONDARY` is supported with the same failover-only semantics
  but not set.
* A non-last provider may use at most `deadline − reserve` (reserve =
  min(15 s, ⅓ of the deadline)), so a hanging Gemini call still leaves Groq
  time to answer within the 45 s server deadline.
* Requests with an `image` block are only routed to image-capable providers;
  with the production pair that means Gemini only (no Groq fallback for meal
  photos).
* Groq free tier: 30 RPM, 1 K requests/day, **8 K tokens/minute** for the
  gpt-oss models. A full coach turn (system prompt + 22 tool schemas +
  history) can exceed 8 K tokens; Groq then answers 413 and the request fails
  over/out cleanly (`upstream_error`, "too large for groq"). Since tool
  routing (see *Speed*), typical coach requests are ≈ 2–3 K tokens and fit;
  upgrade the Groq tier only if it must carry many requests per minute.

## Tool catalogue

All schemas are `type: object`, `additionalProperties: false`, < 4 KB. Every
result carries `provenance {sources, as_of, date_range, note}` and a `missing`
list so the model can say what's unavailable. Calculations are deterministic
Dart (sums, `remaining = target − consumed`, Epley e1RM, adherence).

| Tool | Args (summary) | Write | Consent |
|---|---|---|---|
| get_today_dashboard | – | | health |
| get_nutrition_summary | date \| start_date,end_date (≤31 d) | | health |
| search_food_database | query, limit≤20 (local `foods` only) | | none |
| log_food | date?, meal_type, items[1–10]{name, food_id?, grams?, servings?, calories, macros} | ✔ | health |
| update_food_entry | entry_id, meal_type?, grams?, servings?, calories?, macros? | ✔ | health |
| get_water_summary | date \| range | | health |
| log_water | amount_ml 50–2000 | ✔ | health |
| get_steps_summary | date \| range (HC preferred, staleness flag) | | health |
| get_workout_history | start/end (≤90 d), limit≤20 | | health |
| get_strength_progress | exercise, limit≤20 | | health |
| get_running_activities | start/end, sport_type, limit (Health Connect + manual only) | | health |
| get_strava_activities / analyze_strava_activity | – | | none — **policy notice only** |
| get_calendar_events | start/end (≤14 d); reports not-connected | | none |
| suggest_schedule | date, duration_min, earliest/latest HH:MM, buffer, max_slots (read-only) | | none |
| get_habit_summary | date \| range | | none |
| log_mood | mood 1–5, energy?, stress?, tags?, note? | ✔ | health |
| get_journal_summary | range ≤31 d → counts, dates, ≤10 × 200-char excerpts | | **journal** |
| get_competition_countdown | – (calendar days in the event's IANA tz) | | none |
| get_weekly_report | week_start? | | health |
| get_profile_and_goals | – (targets, diet, restrictions, injuries) | | health |
| remember_preference | category, content → `ai_memories` approved=false | | none |
| record_recommendation | kind, content → `ai_recommendations` pending | | none |

`log_food` saves items without a `food_id` with `verification = 'estimate'`,
`source = 'ai_estimate'`; matched foods are scaled from the stored food
(grams or servings) and keep its verification. Write handlers use deterministic
row ids derived from the idempotency key + insert-or-ignore, so even a crash
between write and audit cannot duplicate rows.

**Nutrition estimates (wired):** `AiFoodTextEstimator` and
`AiMealPhotoAnalyzer` (`lib/features/coach/data/ai_nutrition_estimators.dart`,
bound in `lib/app/overrides.dart`) call `ai-chat` through `AiTextService` with
**only** a `propose_food_items` tool (name, quantity, grams, kcal, protein_g,
carbs_g, fat_g, confidence) and a system prompt that demands estimates. The
tool call is never executed: items come back as `EstimatedFood`, are shown as
ESTIMATE and are saved (`verification = 'estimate'`) only after the user
confirms each one. Photos require `ai_photo_consent`, are picked at ≤ 1280 px /
JPEG q80 and rejected client-side above 1 MB; nothing is sent without consent.

**Bulk food log ("Tell JARVIS what you ate", wired):** `/nutrition/ai-log`
(`AiFoodLogScreen`) sends a whole pasted/dictated day (≤ 4 000 chars, wrapped
as untrusted data between `<<<FOOD_LOG … FOOD_LOG>>>`) in ONE call with only a
`log_food_items` tool (name, quantity, grams, kcal, protein/carbs/fat/fiber,
`meal_type` breakfast|lunch|dinner|snack|unknown, confidence, note; plus an
`unparsed` list), `max_tokens` 4 000. `AiFoodLogParser`
(`lib/features/coach/data/ai_food_log_parser.dart`) implements the nutrition
`FoodLogParser` contract; the prompt pins eggetarian defaults, Indian portions
and "never invent items". Output then passes the pure `sanitizeFoodLog`
(clamps, kcal recomputed from 4/4/9 when > 20 % off, time-of-day meal default,
dedupe) and is written only on "Log all" via `FoodLogRepository.logAll` (one
transaction, `source = ai_estimate`, `verification = estimate`). "Fast mode"
passes `primaryProvider: 'groq'` to `AiTextService.structuredResult` for that
call only. Live check 2026-10-26 (sample Indian day, 11 items): default order
answered via Groq after 38.5 s (Gemini did not answer in time); forced Groq
8.8 s, ≈ $0.002, all meals and items correct, nothing invented.

**`AiTextService`** (`lib/features/coach/data/ai_text_service.dart`) is the
reusable one-shot API — `complete({system, user, maxTokens})` →
`AiTextResult` and `structured({system, user, toolName, schema, image?})` →
tool arguments or `null` — for features such as the messaging assistant's
`ReplyDrafter` (adapt after merging that branch).

## Persona (JARVIS)

The coach system prompt starts with a configurable persona (AppSettings key
`ai.persona`, editable in AI settings → Persona). Unset = the default
**JARVIS** persona: addresses the user as "Sreevallabh", calm, formal, dryly
witty British-butler tone, concise. An empty value restores the plain
"Athlete OS Coach" voice. The persona sets tone only — the prompt states that
the rules (no invented data, safety, consent, Strava exclusion…) always take
precedence. Persona text is capped at 1 500 chars. One-shot estimators do not
use the persona.

## Sign-in

When Supabase is configured the app signs in **anonymously on first launch**
(`ensureAnonymousSession` in `coachBootstrap`, not awaited, never throws);
supabase_flutter persists the session. AI settings can **link an email** to
the anonymous account (`updateUser(email)` → email-change OTP; if the email
already has an account it signs in to that one instead). An explicit
"Sign out" disables the automatic anonymous sign-in until the user signs in
again.

## Memory model

* `ai_memories` rows: `category` (preference/goal/routine/context), `content`,
  `origin` (user/ai_suggested), `approved`.
* The model can only **propose** (`remember_preference` → approved=false).
  Users approve/edit/reject in **Coach memory**; only approved memories (newest
  20) go into the system prompt.
* The system prompt contains: rules, current date/time + tz, name, targets and
  diet (health consent only), active injuries/restrictions (health consent
  only), approved memories. **No logs or history** — facts come from tools.

## Budgets & usage

* Each call records `ai_usage` (request_id unique, provider, model,
  credential alias, tokens, `cost_usd`, status, latency).
* Budget = min(user preference, `user_settings.monthly_budget_usd`,
  `AI_MONTHLY_BUDGET_USD`); global spend is also capped by
  `AI_MONTHLY_BUDGET_USD`. At ≥100 % requests are refused (`budget_exceeded`);
  `meta.budget.alerts` lists 50/80/100 % thresholds reached.
* AI settings shows month-to-date requests, tokens and spend from `ai-status`.

## Retry, rotation and fallback semantics

| Failure | Action |
|---|---|
| Transient (5xx, 529 overloaded, network, timeout) or 429 with Retry-After ≤ 20 s | Retry the **same key**, full-jitter exponential backoff (base 500 ms, cap 8 s, Retry-After as floor), max 3 attempts within the deadline (min(timeout_ms, 45 s)). |
| Retries exhausted | Counts toward the provider circuit breaker; move to the **next provider**. Keys are **never rotated on a transient failure**. |
| 401/403 invalid key | Mark key `invalid` (persisted), try the provider's next key. |
| Quota / spend cap / insufficient_quota / long Retry-After | Key `cooldown_until` (Retry-After, quota reset, or 1 h for quota / 60 s for rate limits), try the next key. |
| 400 bad request | Stop; `invalid_request`; no rotation or fallback. |
| No healthy key left or circuit open | Fall back to the next provider in `primary → fallback_providers → AI_PROVIDER_ORDER`. |

**Circuit breaker** (per provider, state shared via `ai_circuit_state`): opens
after 5 consecutive failures, half-open after 60 s (one trial), closes on
success.

**Idempotency:** the client generates one `request_id` per model call and
reuses it on retry; the server caches successful responses in
`ai_response_cache` (24 h; a different user's id → 409). Tool side effects are
idempotent by `ai_tool_actions.idempotency_key = conversationId:toolCallId`.
Known gap: two simultaneous in-flight requests with the same id are not
de-duplicated (the client never does this).

## Security

* Provider keys exist only as Supabase function secrets; never in the app,
  never logged, never returned (`ai-status` lists aliases + health only).
  Errors are redacted (`redact.ts` patterns + exact configured key values;
  client `redactSecrets`).
* Functions require a Supabase JWT (`verify_jwt = true` + `auth.getUser`).
* RLS on every table (`user_id = auth.uid()`); server tables (`ai_usage`,
  `ai_credential_health`, `ai_circuit_state`, `ai_response_cache`,
  `api_rate_limits`) have no client policies.
* Rate limit 30 req/min/user (`AI_RATE_LIMIT_PER_MIN`), test calls 5/min.
* Input limits: body 256 KB (1.6 MB when the request has an image), 60
  messages, 40 blocks/message, 16 000 chars per text/tool result, 12 000-char
  system prompt, 40 tools, 4 KB per schema, 1 image ≤ 1 MB decoded
  (JPEG/PNG/WebP, base64 without `data:` prefix).
* Model output is untrusted: tool args are schema-validated client-side;
  writes need explicit approval; the model cannot change targets or approve
  its own memories.

## Strava exclusion (Strava API Agreement §5.3, effective 2026-06-01)

Strava data (or anything derived from it) is never sent to a model:
* every cardio query filters `source IN ('health_connect','manual')`;
* health samples whose `source_app` contains "strava" are excluded;
* `get_strava_activities` / `analyze_strava_activity` return only a policy
  notice pointing to the on-device, rule-based analysis on the activity screen;
* a test seeds Strava runs and asserts no tool output contains them.
The server cannot distinguish Strava-derived content, so this is enforced in
the client tool layer.

## Deploy

The production project is live — exact commands, project ref and
redeploy/log instructions are in [BACKEND_DEPLOY.md](BACKEND_DEPLOY.md).
Summary:

```bash
supabase link --project-ref gbvtlzkcqjligajsnoll -p <db-password>
supabase db push --linked
supabase secrets set --env-file <tmp file>   # names below; values never committed
supabase functions deploy ai-chat ai-status strava-oauth --project-ref gbvtlzkcqjligajsnoll --use-api
```

Secrets: `GEMINI_API_KEY`, `GEMINI_API_KEY_SECONDARY`, `GROQ_API_KEY`,
`AI_PROVIDER_ORDER=gemini,groq`, `AI_DEFAULT_MODEL_GEMINI=gemini-3.6-flash`,
`AI_DEFAULT_MODEL_GROQ=openai/gpt-oss-120b`, `AI_MONTHLY_BUDGET_USD=10`,
`AI_RATE_LIMIT_PER_MIN=30`. Anonymous sign-ins are enabled and email OTP is 6
digits (Management API). Still to do by hand: schedule `select
purge_ai_response_cache(); select purge_api_rate_limits();` hourly with
pg_cron, and custom SMTP for email codes (see BACKEND_DEPLOY.md).

Local tests (no Deno install needed):

```bash
cd supabase/functions
npx -y deno@2.9.6 test --allow-env --no-check=remote _shared/ ai-chat/ ai-status/
npx -y deno@2.9.6 check ai-chat/index.ts ai-status/index.ts
```

## Safe credential rotation (CLI)

Secrets are read per request, so `supabase secrets set` takes effect without a
redeploy (redeploying is harmless). Never paste keys on a shared terminal:
prefer `--env-file` with a temporary file you delete afterwards.

1. Create the new key at the provider (Google AI Studio / Groq console).
2. Stage it as the secondary:
   `supabase secrets set --env-file new.env --project-ref gbvtlzkcqjligajsnoll`
   where `new.env` contains `GEMINI_API_KEY_SECONDARY=<new>` (delete the file).
3. Verify in AI settings → Test connection (or `ai-status`
   `{"action":"test","provider":"gemini"}`) that alias `secondary` is `ok`.
4. Swap: set `GEMINI_API_KEY=<new>` and put the previous secondary back as
   `GEMINI_API_KEY_SECONDARY` (or `supabase secrets unset
   GEMINI_API_KEY_SECONDARY`), test again.
5. Revoke the old key at the provider. Because invalid keys are skipped
   automatically, a revoked primary degrades to the secondary instead of
   failing.
6. If a key was marked `invalid` in `ai_credential_health`, the new value is
   not retried automatically; clear it with
   `supabase db query --linked "delete from public.ai_credential_health where provider='gemini'"`
   (or run "Test connection", which marks a working key `ok`).

Same steps for Groq with `GROQ_API_KEY` / `GROQ_API_KEY_SECONDARY`.

## Live verification (2026-10-25)

Real calls against project `gbvtlzkcqjligajsnoll` from a script that signs up
an anonymous user via `POST /auth/v1/signup` with the publishable key and then
calls the functions with that user's JWT. No secrets were printed or stored.
Latencies are wall-clock from a client in India, including the edge function.

**First attempt (failed, fixed):** with `gemini-3.8-flash` as default, both
Gemini keys timed out in "Test connection" (20 s) and a coach turn returned
`504 timeout` after 47.7 s **without** falling back to Groq: the primary's
retries consumed the whole 45 s deadline. Direct probes showed 3.8-flash was
overloaded (`503 UNAVAILABLE` "high demand" / 60 s hangs). Fixes: the
fallback reserve in `runWithFallback` (non-last providers leave
min(15 s, ⅓ deadline) for the next one), `AI_DEFAULT_MODEL_GEMINI=gemini-3.6-flash`,
and "Test connection" prefers the default model on price ties.

**Final run (all green):**

| Step | HTTP | Provider / model | Latency | Tokens in/out | Cost (USD) | Result |
|---|---|---|---|---|---|---|
| Anonymous sign-up | 200 | – | 1.4 s | – | – | `is_anonymous: true`, session issued |
| `ai-status` (GET) | 200 | – | 4.4 s | – | – | order `gemini,groq`; gemini primary+secondary `ok`, groq primary `ok`, circuits closed |
| `ai-status` test | 200 | gemini-3.6-flash ×2, openai/gpt-oss-20b | 1.9 s / 3.8 s / 0.4 s | – | – | all 3 credentials `ok` |
| Coach turn 1 (tool schema `get_steps_summary`) | 200 | gemini / gemini-3.6-flash | 25.0 s (first call) | 121 / 119 | 0.000537 | normalised `tool_call get_steps_summary {"date":"2026-10-25"}`, `stop_reason: tool_use` |
| Coach turn 2 (`tool_result` 8 421 steps) | 200 | gemini / gemini-3.6-flash | 3.0 s | 293 / 55 | 0.000426 | text: "You walked 8,421 steps today (Goal: 10,000 steps)." |
| Same flow, `primary_provider: groq` | 200 / 200 | groq / openai/gpt-oss-120b | 1.5 s / 1.3 s | 187/71, 256/87 | 0.000071 / 0.000091 | tool_call then final text |
| **Forced fallback** (both Gemini secrets temporarily set to invalid keys) | 200 / 200 | groq / openai/gpt-oss-120b | 4.3 s / 1.6 s | 187/59, 256/104 | 0.000063 / 0.000101 | `fallback_used: true`, `attempts: 3` (gemini primary → gemini secondary → groq); both Gemini aliases marked `invalid`. Real keys restored afterwards, health rows cleared, "Test connection" `ok` for both (6.0 s / 1.5 s). |
| Image block (PNG) | 200 | gemini / gemini-3.6-flash | 5.1 s | 1106 / 94 | 0.001182 | "The Flutter logo." |
| Food estimate (`propose_food_items` only) | 200 | gemini / gemini-3.6-flash | 19.8 s | 395 / 723 | 0.003008 | 2 items (Chapati 70 g 203 kcal, Dal tadka 200 g 204 kcal) |
| Food estimate, `primary_provider: groq` | 200 | groq / openai/gpt-oss-120b | 3.8 s | 450 / 939 | 0.000631 | 2 items |
| `strava-oauth` (no Strava secrets) | 500 | – | – | – | – | `{"error":"server_not_configured","message":"Strava is not configured on the server (STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET are unset)."}` |
| `ai-chat` with only the publishable key (no user JWT) | 401 | – | – | – | – | `unauthorized` |

Observations: Gemini 3.x "thinking" makes first/structured calls slow
(20–25 s) and output-token heavy; Groq is ~10× faster and cheaper but limited
to 8 K tokens/minute on the free tier. Total spend for the whole verification
≈ $0.01.


## Costs

Paid: every coach message and tool round (provider tokens, billed to the
backend owner), "Test connection" calls, optional AI food/photo estimates.
Supabase free tier covers personal use. Typical coach turn with 1–2 tool rounds
on claude-sonnet-5-5 ≈ 6–12 K input + 300–800 output tokens ≈ $0.02–0.03;
on claude-haiku-5-5 ≈ $0.001; on gemini-3.6-flash ≈ $0.01–0.02; on
openai/gpt-oss-120b ≈ $0.002. A food estimate ≈ $0.003 (Gemini, thinking
tokens dominate) or $0.0006 (Groq); a meal photo ≈ $0.002–0.004. Everything
else in the app is on-device and free.
Spending stops at the monthly budget.

## Gemini thinking budget (fixed 2026-10-26)

Gemini 3.x Flash models always reason, and thought tokens count toward `maxOutputTokens`. Live testing showed a 256-token request truncated mid-sentence (252 output tokens, mostly thoughts). The Gemini adapter now sends `thinkingConfig.thinkingLevel = low` (override with the `AI_GEMINI_THINKING_LEVEL` secret: minimal | low | medium | high) and adds `GEMINI_THINKING_HEADROOM` (1,024) tokens so `max_tokens` means visible answer tokens. Verified live: greeting 5 s / complete; 2-sentence nutrition answer 14 s / complete.

