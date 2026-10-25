# AI Coach — architecture & operations

The coach is a tool-using agent. The **agent loop runs on the device**; model
calls go through a **Supabase Edge Function** that holds the provider keys.
Health data stays in the local Drift database and only the minimal tool results
a question needs are sent, and only after the user consents.

```
 ┌──────────────────────── Android app (Flutter) ────────────────────────┐
 │ CoachScreen ─▶ CoachController (Notifier, agent loop, ≤6 tool rounds) │
 │                  │  system prompt (date/tz, profile, ≤20 memories)    │
 │                  │  tool schemas (22+)            ▲ tool_result blocks│
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
 │   → adapter (anthropic | openai | gemini) → normalised response         │
 │   → ai_usage + ai_response_cache                                        │
 │ ai-status: providers/aliases/health (no key values), usage, test calls  │
 └─────────────────────────────────────────────────────────────────────────┘
```

## Request flow

1. User sends a message → persisted to `ai_messages` (role `user`).
2. `CoachController` builds the request: system prompt, the last ≤40 messages
   (≤150 KB, never starting on an orphaned tool result), all tool schemas,
   preferences, and a fresh `request_id`.
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
6. Errors show a banner; **Retry re-sends the same `request_id`**, so the server
   returns its cached response (24 h) instead of paying twice.

When the build has no `SUPABASE_URL`/`SUPABASE_ANON_KEY`, or the user isn't
signed in, `UnconfiguredAiBackend`/`AiBackendState.signedOut` is used: the coach
shows a setup banner and **never fabricates an answer**.

### Wire contract (normalised)

Request: `{request_id, conversation_id, system, messages:[{role:user|assistant,
content:[Block]}], tools:[{name, description, input_schema}], preferences:
{primary_provider, model, fallback_providers, max_tokens, timeout_ms,
max_retries, monthly_budget_usd}}`.

Blocks: `text{text}` · `tool_call{id,name,arguments,provider_meta?}` (assistant)
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
| Gemini | `POST /v1beta/models/{m}:generateContent`, `x-goog-api-key` | `functionDeclarations` (schema sanitised), `functionCall` ↔ `functionResponse` | `thoughtSignature` round-tripped through `provider_meta`; calls from other providers get the documented skip-validator placeholder. |

### Model defaults and how to change them

Defaults are configuration, not code: `AI_DEFAULT_MODEL_ANTHROPIC`
(`claude-sonnet-5-5`), `AI_DEFAULT_MODEL_OPENAI` (`gpt-5.4-mini`),
`AI_DEFAULT_MODEL_GEMINI` (`gemini-3.8-flash`). Users may pick a model in
**AI settings**; the server only honours models on the allowlist (price-table
models of that provider + `AI_ALLOWED_MODELS_<PROVIDER>`). To add a model:
add it to `AI_PRICE_TABLE_JSON` (or `DEFAULT_PRICES` in `budget.ts`) and, if
needed, the allowlist env var; redeploy.

Default prices (USD / 1M tokens in/out): claude-sonnet-5-5 2/10,
claude-haiku-5-5 0.10/0.50 (≤100K-token prompts; 0.50/2.50 above),
claude-opus-5-5 4/20, gpt-5.4-mini 0.75/4.50, gemini-3.8-flash 0.75/3.75.

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

**Nutrition estimator hook:** a nutrition `FoodTextEstimator` can be backed by
the same pipeline: send `"estimate: <text>"` through `ai-chat` with only the
`log_food` schema and read the proposed `items` from the (unexecuted)
`tool_call`, or call `logFoodTool.handler` after the user confirms.

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
* Input limits: body 256 KB, 60 messages, 40 blocks/message, 16 000 chars per
  text/tool result, 12 000-char system prompt, 40 tools, 4 KB per schema.
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

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                                   # applies supabase/migrations
supabase secrets set ANTHROPIC_API_KEY=... OPENAI_API_KEY=... GEMINI_API_KEY=... \
  AI_PROVIDER_ORDER=anthropic,openai,gemini AI_MONTHLY_BUDGET_USD=10
supabase functions deploy ai-chat ai-status
```

Then enable **Anonymous** and/or **Email (OTP)** sign-in under Auth →
Providers (the app verifies a 6-digit code, so the "Magic Link" email template
must include `{{ .Token }}`), schedule `select purge_ai_response_cache(); select
purge_api_rate_limits();` hourly with pg_cron, and put `SUPABASE_URL` +
`SUPABASE_ANON_KEY` into `config/dev.json`. In the app: AI settings → sign in →
"Test connection".

Local tests (no Deno install needed):

```bash
cd supabase/functions
npx -y deno@2.9.6 test --allow-env --no-check=remote _shared/ ai-chat/ ai-status/
npx -y deno@2.9.6 check ai-chat/index.ts ai-status/index.ts
```

## Safe credential rotation

1. Create the new key at the provider.
2. `supabase secrets set ANTHROPIC_API_KEY_SECONDARY=<new>` and redeploy
   (`supabase functions deploy ai-chat ai-status`).
3. Verify in AI settings → Test connection (or `ai-status` `{action:"test"}`)
   that alias `secondary` is `ok`.
4. Swap: set `ANTHROPIC_API_KEY=<new>`, unset/replace the secondary, redeploy,
   test again.
5. Revoke the old key at the provider. Because invalid keys are skipped
   automatically, a revoked primary degrades to the secondary instead of
   failing.

## Costs

Paid: every coach message and tool round (provider tokens, billed to the
backend owner), "Test connection" calls, optional AI food/photo estimates.
Supabase free tier covers personal use. Typical coach turn with 1–2 tool rounds
on claude-sonnet-5-5 ≈ 6–12 K input + 300–800 output tokens ≈ $0.02–0.03;
on claude-haiku-5-5 ≈ $0.001. Everything else in the app is on-device and free.
Spending stops at the monthly budget.
