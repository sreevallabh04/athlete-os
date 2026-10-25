-- Schedule hourly housekeeping with pg_cron (available on all Supabase plans).
-- Idempotent: re-running unschedules existing jobs with the same name first.

create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'purge_ai_response_cache') then
    perform cron.unschedule('purge_ai_response_cache');
  end if;
  if exists (select 1 from cron.job where jobname = 'purge_api_rate_limits') then
    perform cron.unschedule('purge_api_rate_limits');
  end if;
end;
$$;

-- Idempotency cache entries are only useful for 24 h (client retries).
select cron.schedule(
  'purge_ai_response_cache',
  '7 * * * *',
  $$select public.purge_ai_response_cache()$$
);

-- Rate-limit windows older than an hour are dead weight.
select cron.schedule(
  'purge_api_rate_limits',
  '17 * * * *',
  $$select public.purge_api_rate_limits()$$
);
