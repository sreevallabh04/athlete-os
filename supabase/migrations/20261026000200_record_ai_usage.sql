-- Append-safe AI usage accounting.
--
-- Before: edge functions upserted ai_usage by request_id, so re-sending an old
-- request_id after its 24 h response-cache entry expired OVERWROTE the earlier
-- row. A paid row (status 'ok', cost > 0) could be replaced by a 'refused' or
-- 'error' row with cost 0 (or by a cheaper re-run), lowering month-to-date
-- spend and bypassing the per-user and global budgets. A request_id first used
-- by another user could also be re-attributed.
--
-- record_ai_usage() keeps the client idempotency semantics for retries (an
-- 'error'/'refused' row of the SAME user is replaced, e.g. a retry that then
-- succeeds) but never replaces a paid 'ok' row or another user's row: those
-- cases get a new row under a suffixed key, so every provider call that cost
-- money stays counted in the month it happened.
--
-- Called with the service role only (security invoker; service_role already
-- owns all privileges on ai_usage and its sequence).

create or replace function public.record_ai_usage(
  p_user uuid,
  p_request_id text,
  p_provider text,
  p_model text,
  p_credential_alias text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cost_usd numeric,
  p_status text,
  p_latency_ms integer
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  n integer;
begin
  insert into public.ai_usage as u (
    user_id, request_id, provider, model, credential_alias,
    input_tokens, output_tokens, cost_usd, status, latency_ms
  )
  values (
    p_user, p_request_id, p_provider, p_model, p_credential_alias,
    p_input_tokens, p_output_tokens, p_cost_usd, p_status, p_latency_ms
  )
  on conflict (request_id) do update set
    provider = excluded.provider,
    model = excluded.model,
    credential_alias = excluded.credential_alias,
    input_tokens = excluded.input_tokens,
    output_tokens = excluded.output_tokens,
    cost_usd = excluded.cost_usd,
    status = excluded.status,
    latency_ms = excluded.latency_ms,
    created_at = now()
  where u.user_id = excluded.user_id and u.status <> 'ok';
  get diagnostics n = row_count;

  if n = 0 then
    -- Existing row is a paid answer or belongs to another user: keep it and
    -- record this call separately.
    insert into public.ai_usage (
      user_id, request_id, provider, model, credential_alias,
      input_tokens, output_tokens, cost_usd, status, latency_ms
    )
    values (
      p_user, p_request_id || ':' || replace(pg_catalog.gen_random_uuid()::text, '-', ''),
      p_provider, p_model, p_credential_alias,
      p_input_tokens, p_output_tokens, p_cost_usd, p_status, p_latency_ms
    );
  end if;
end;
$$;

revoke execute on function public.record_ai_usage(uuid, text, text, text, text, integer, integer, numeric, text, integer)
  from public, anon, authenticated;
grant execute on function public.record_ai_usage(uuid, text, text, text, text, integer, integer, numeric, text, integer)
  to service_role;
