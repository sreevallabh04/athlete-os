-- Strava OAuth tokens, held server-side only.
--
-- The Strava client secret and refresh tokens must never reach the mobile app.
-- The `strava-oauth` Edge Function (service role) is the only reader/writer of
-- this table: it exchanges authorization codes, refreshes access tokens (always
-- storing the latest, possibly rotated, refresh token) and revokes access.
-- The app only ever receives short-lived access tokens from that function.

create table if not exists public.strava_tokens (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  athlete_id    bigint not null,
  refresh_token text not null,
  access_token  text,
  expires_at    timestamptz,
  scope         text,
  updated_at    timestamptz not null default now()
);

-- RLS on with NO policies: anon/authenticated clients get zero rows and cannot
-- write. The service role bypasses RLS, so only the Edge Function has access.
alter table public.strava_tokens enable row level security;

-- Defence in depth: also strip table privileges from client-facing roles.
revoke all on public.strava_tokens from anon, authenticated;

comment on table public.strava_tokens is
  'Strava OAuth tokens per user. Service-role only (RLS enabled, no policies, '
  'privileges revoked from anon/authenticated). Accessed exclusively by the '
  'strava-oauth Edge Function; refresh tokens are never returned to clients.';
