# Backend deploy (Supabase) — production runbook

| | |
|---|---|
| Project | `athlete-os`, ref **`gbvtlzkcqjligajsnoll`**, region ap-south-1 (Mumbai), org `krljqwvejwfziznrwntc` |
| URL | `https://gbvtlzkcqjligajsnoll.supabase.co` |
| Functions | `ai-chat`, `ai-status`, `strava-oauth` (all `verify_jwt = true`) |
| Migrations | `20261025000000_init`, `20261025000100_strava_tokens`, `20261025000200_groq_provider` — 42 public tables, RLS on all 42; `db advisors --type security`: no issues |
| CLI | `npx -y supabase@2.122.0 …` (no global install; no Docker needed with `--use-api`) |
| Went live | 2026-10-25 |

All commands run from the repo root. Secrets come from the owner's local,
git-ignored `.env`; **never** paste key values into a terminal that is logged,
into tracked files, or into chat.

## 1. Link and migrate

```bash
supabase login                                            # once per machine
supabase link --project-ref gbvtlzkcqjligajsnoll -p "$SUPABASE_DB_PASSWORD"
supabase db push --linked                                  # applies supabase/migrations
supabase migration list --linked                           # local == remote for every row
supabase db advisors --linked --type security --level warn # expect "No issues found"
supabase db query --linked "select count(*) filter (where c.relrowsecurity) as rls_on, count(*) as tables
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'"
```

New schema changes = a new timestamped file in `supabase/migrations/` (keep
`enable row level security` + policies on every new table), then
`supabase db push --linked`.

## 2. Secrets (names only)

| Secret | Value / source |
|---|---|
| `GEMINI_API_KEY` | `.env` `GEMINI_API_KEY` |
| `GEMINI_API_KEY_SECONDARY` | `.env` `GEMINI_API_KEY_2` — **failover only** (invalid/revoked/out-of-quota primary). Not for load spreading: Google's Gemini API terms prohibit circumventing rate limits, so `_3`/`_4` are deliberately not deployed. |
| `GROQ_API_KEY` | `.env` `GROQ_API_KEY` |
| `AI_PROVIDER_ORDER` | `gemini,groq` |
| `AI_DEFAULT_MODEL_GEMINI` | `gemini-3.6-flash` (3.8-flash was overloaded at go-live) |
| `AI_DEFAULT_MODEL_GROQ` | `openai/gpt-oss-120b` |
| `AI_MONTHLY_BUDGET_USD` | `10` (global cap; also the per-user default) |
| `AI_RATE_LIMIT_PER_MIN` | `30` |
| `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET` | **not set** — `strava-oauth` answers `500 server_not_configured` with a clear message |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` etc. are
injected by Supabase.

How they were set (values never echoed): a small script parsed `.env`, wrote a
temporary env file in `%TEMP%`, then

```bash
supabase secrets set --env-file "$TMP/secrets.env" --project-ref gbvtlzkcqjligajsnoll
rm "$TMP/secrets.env"
supabase secrets list --project-ref gbvtlzkcqjligajsnoll   # shows names + digests only
```

Non-secret settings can be set inline, e.g.
`supabase secrets set AI_DEFAULT_MODEL_GEMINI=gemini-3.8-flash --project-ref gbvtlzkcqjligajsnoll`.
Secrets are read per request; no redeploy is needed. Key rotation:
[AI_AGENT.md → Safe credential rotation](AI_AGENT.md#safe-credential-rotation-cli).

## 3. Deploy / redeploy functions

```bash
supabase functions deploy ai-chat ai-status strava-oauth \
  --project-ref gbvtlzkcqjligajsnoll --use-api
```

`--use-api` bundles server-side (Docker is not installed on the dev machine).
Before deploying run the Deno tests:

```bash
cd supabase/functions
npx -y deno@2.9.6 test --allow-env --no-check=remote _shared/ ai-chat/ ai-status/
npx -y deno@2.9.6 check ai-chat/index.ts ai-status/index.ts strava-oauth/index.ts
```

## 4. Auth configuration

Applied with the Management API (`PATCH /v1/projects/{ref}/config/auth`)
using the CLI's access token (Windows Credential Manager entry
`Supabase CLI:supabase`); `supabase config push` was **not** used because it
would also push every unspecified `[auth]` default. `supabase/config.toml`
mirrors these values for local runs.

| Setting | Value |
|---|---|
| `external_anonymous_users_enabled` | `true` (the app signs in anonymously on first launch) |
| `external_email_enabled` | `true` |
| `mailer_otp_length` / `mailer_otp_exp` | `6` / `600` s (the app verifies a 6-digit code) |
| `site_url` | `athleteos://localhost/auth` |
| `uri_allow_list` | `athleteos://localhost/**` |

Equivalent dashboard clicks: Authentication → Sign In / Providers → enable
"Allow anonymous sign-ins"; Email provider → OTP length 6, expiry 600.

**Manual follow-up for email codes (not possible tonight):** on the free plan
with Supabase's built-in mailer, email templates cannot be edited (API:
"Email template modification is not available for free tier projects using
the default email provider") and the built-in mailer only delivers to the
project team's addresses, ~2 emails/hour. The default magic-link email
contains a link, not the 6-digit code. To make "Email me a code" work for
everyone:

1. Dashboard → Authentication → Emails → SMTP settings: configure a custom
   SMTP provider (e.g. Resend, Brevo, SES).
2. Edit the **Magic Link**, **Confirm signup** and **Change email address**
   templates to include `{{ .Token }}` (e.g.
   `<h2>{{ .Token }}</h2><p>Enter this code in Athlete OS.</p>`).

Anonymous sign-in (the default path) does not depend on email. Linking an
email to an anonymous account already works via the link in the
"Change email address" email (it confirms the address server-side).

## 5. Client configuration

`config/dev.json` (git-ignored; template `config/dev.example.json`) holds the
public identifiers: `SUPABASE_URL`, `SUPABASE_ANON_KEY` (= the project's
**publishable** key `sb_publishable_…`, from
`supabase projects api-keys --project-ref gbvtlzkcqjligajsnoll`),
`OFF_CONTACT_EMAIL`, and empty `STRAVA_CLIENT_ID` / `GOOGLE_WEB_CLIENT_ID` /
`USDA_API_KEY`. Copies live in each local checkout's `config/dev.json`.
Build/run with `--dart-define-from-file=config/dev.json`. Never put the
`sb_secret_…` / service-role key in the app.

## 6. Logs and health

Function logs are structured JSON lines (`request_id`, `provider`, `alias`,
`status`, `latency_ms` — never keys or prompts). **CLI 2.122.0 has no
`supabase functions logs` command** (subcommands: list, delete, download,
deploy, new, serve), so view them in the dashboard:
<https://supabase.com/dashboard/project/gbvtlzkcqjligajsnoll/functions> →
`ai-chat` → Logs / Invocations (or Logs Explorer). If a later CLI adds it,
the command is `supabase functions logs ai-chat --project-ref gbvtlzkcqjligajsnoll`.
The same per-request facts are also in the `ai_usage` table:

```bash
# Usage and spend this month
supabase db query --linked "select provider, model, status, count(*), sum(input_tokens) in_tok,
  sum(output_tokens) out_tok, round(sum(cost_usd)::numeric, 4) usd
  from public.ai_usage where created_at >= date_trunc('month', now())
  group by 1,2,3 order by usd desc"
# Credential health / circuit breakers
supabase db query --linked "select * from public.ai_credential_health"
supabase db query --linked "select * from public.ai_circuit_state"
```

In the app: AI settings → "Test connection" runs a tiny call per configured
key.

Housekeeping still to schedule (pg_cron, hourly):
`select purge_ai_response_cache(); select purge_api_rate_limits();`

## 7. Cost notes

* Supabase free tier covers this personal project (500 MB DB, 500 K edge
  function invocations/month). Free projects pause after a week of
  inactivity — open the dashboard to resume.
* Gemini and Groq keys are on free tiers today; `ai_usage.cost_usd` records
  what the same calls would cost on paid tiers. Gemini Flash prices double on
  2027-01-01 (update `DEFAULT_PRICES` in `supabase/functions/_shared/budget.ts`
  or `AI_PRICE_TABLE_JSON`).
* Typical: coach turn with a tool round ≈ $0.001–0.02 (Gemini) / ≈ $0.0002–0.002
  (Groq); food estimate ≈ $0.003 / $0.0006; meal photo ≈ $0.002–0.004 (Gemini
  only). The global `AI_MONTHLY_BUDGET_USD=10` stops all AI calls at 100 %.
* The go-live verification cost ≈ $0.01 (see AI_AGENT.md → Live verification).
