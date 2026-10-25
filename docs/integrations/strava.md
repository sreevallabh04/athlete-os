# Strava integration

Athlete OS imports runs and other activities from Strava. OAuth tokens are
handled by a Supabase Edge Function so the client secret and refresh tokens
never live on the phone.

## 1. Register the Strava app

1. Go to <https://www.strava.com/settings/api> and create an application.
2. **Authorization Callback Domain**: `localhost`.
3. Note the **Client ID** (public) and **Client Secret** (server only).

The app uses the redirect URI `athleteos://localhost/strava`. The
AndroidManifest already declares the `flutter_web_auth_2` `CallbackActivity`
for the `athleteos` scheme, so no manifest changes are needed.

**Single-player mode**: new Strava apps have an athlete capacity of 1 (only the
owner's account can connect). That is fine for this single-user app; no review
by Strava is required.

## 2. Configure the app

Copy `config/dev.example.json` to `config/dev.json` and fill in:

```json
{
  "SUPABASE_URL": "https://YOUR-PROJECT-REF.supabase.co",
  "SUPABASE_ANON_KEY": "your-public-anon-key",
  "STRAVA_CLIENT_ID": "12345"
}
```

Run with `flutter run --dart-define-from-file=config/dev.json`.

The client secret is **never** put in the app or in `config/dev.json`.

## 3. Configure Supabase

```bash
supabase db push                       # or paste the SQL in the dashboard SQL editor
supabase functions deploy strava-oauth
supabase secrets set STRAVA_CLIENT_ID=12345 STRAVA_CLIENT_SECRET=xxxxxxxx
# optional, defaults to athleteos://localhost/strava
supabase secrets set STRAVA_ALLOWED_REDIRECT=athleteos://localhost/strava
```

- Migration: `supabase/migrations/20261025000100_strava_tokens.sql` creates
  `public.strava_tokens` with RLS enabled, **no client policies**, and all
  privileges revoked from `anon`/`authenticated`. Only the service role (the
  Edge Function) can read or write it.
- The function requires a **signed-in Supabase user session** (the app's backend
  sign-in). Calls made with only the anon key are rejected with `401`.

### Edge Function actions

All calls: `POST /functions/v1/strava-oauth` with
`Authorization: Bearer <user JWT>` and a JSON body.

| Action | Body | Does |
| --- | --- | --- |
| `exchange` | `{action, code, redirect_uri, scope}` | Swaps the auth code for tokens, checks scope, stores tokens |
| `refresh` | `{action}` | Returns the stored access token if valid > 10 min, else refreshes (storing any rotated refresh token) |
| `revoke` | `{action}` | Deauthorizes on Strava (best effort) and deletes the stored row |

Success for `exchange`/`refresh`:
`{access_token, expires_at (epoch s), athlete_id, scope}`. Refresh tokens are
never returned. Errors: `{error, message?}`, e.g. `reauthorize_required` (401),
`not_connected` (404), `insufficient_scope` (400), `rate_limited` (429 with
`Retry-After`).

## OAuth flow

1. App opens `https://www.strava.com/oauth/mobile/authorize` with
   `client_id`, `redirect_uri=athleteos://localhost/strava`,
   `response_type=code`, `approval_prompt=auto`,
   `scope=read,activity:read_all` and a random `state`.
2. Strava redirects to `athleteos://localhost/strava?code=...&scope=...&state=...`.
3. The app verifies `state` matches, then calls `exchange` (forwarding the
   granted `scope` from the redirect).
4. If the user unticked activity access, the app shows "Activity access is
   required" and offers to retry.

## Tokens

- Access tokens last **6 hours**. The app asks the function for a token before
  syncing; the function refreshes when < 10 min remain.
- Refreshing may **rotate** the refresh token; the function always stores the
  latest one.
- If Strava rejects the refresh token (user revoked access on strava.com), the
  row is deleted and the app shows **Needs reconnect**.

## Rate limits

- Overall: **200 requests / 15 min**, **2,000 / day**.
- Read: **100 requests / 15 min**, **1,000 / day**.
- Response headers `X-RateLimit-Limit` / `X-RateLimit-Usage` and
  `X-ReadRateLimit-Limit` / `X-ReadRateLimit-Usage` are tracked; the app stops
  syncing at >= 90% usage of either window and on `429`, resuming after the
  window resets.

## Sync

- First sync: activities from the **last 90 days**.
- Then incremental with `after=<latest start time>`.
- Run detail (`splits_metric`, `laps`) is fetched lazily when a run is opened,
  or eagerly for the 10 latest runs.
- Streams (heart rate, pace, elevation) are fetched on demand for charts and
  **never persisted**.

## Strava API Policy compliance (effective 2026-06-01)

- **Display**: Strava data is shown only to the connected user.
- **Section 5.3, no AI**: Strava data, and anything derived or aggregated from
  it, is **never** sent to the AI coach or any LLM.
  - "Ask AI coach" is disabled for Strava activities.
  - Run reviews for Strava activities are rule-based and labelled
    **"Automated analysis (rule-based, no AI)"**.
  - The coach may only see runs sourced from Health Connect or manual entry,
    even when the same run also exists in Strava.
- **Section 6.2, cache at most 7 days**: on every app start/sync, Strava rows
  with `fetchedAt` older than 7 days are re-fetched or purged. Activities
  deleted on Strava disappear on the next re-sync within that window.
- **Deauthorize**: Integrations -> Strava -> Disconnect deletes all Strava rows
  immediately and calls the function's `revoke` action.

## Branding

- **Connect with Strava** button: Strava orange `#FC5200`, 48dp tall.
- **Powered by Strava** on every screen that shows Strava data.
- **View on Strava** links (bold, `#FC5200`) to
  `https://www.strava.com/activities/{id}`.
- "Strava" is not used in the app name or icon.

## Dedupe with Health Connect

A Strava activity and a Health Connect session are treated as the same workout
when start times are within **+/- 3 min** and distances within **+/- 5%**. It is
shown once, the Strava version is preferred for display, with an "also in Health
Connect" note. The AI coach still only sees the Health Connect copy.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Browser shows "invalid redirect_uri" | Callback Domain on strava.com/settings/api must be `localhost`. |
| Browser does not return to the app | Check the `athleteos` scheme `CallbackActivity` in AndroidManifest. |
| `401 unauthorized` from function | Not signed in to the app backend; sign in and retry. |
| `500 server_not_configured` | Run `supabase secrets set STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=...`. |
| `400 invalid_redirect_uri` | `STRAVA_ALLOWED_REDIRECT` differs from the app's redirect URI. |
| `400 insufficient_scope` | Reconnect and keep "View data about your activities" ticked. |
| `401 reauthorize_required` | Access was revoked on Strava; tap Reconnect. |
| `429 rate_limited` | Wait for the 15-minute window to reset. |
| Second account cannot connect | Single-player mode (capacity 1); only the app owner can connect. |
