// Supabase Edge Function entrypoint: GET|POST /functions/v1/ai-status
import { getUser, serviceClient } from "../_shared/auth.ts";
import { denoEnv } from "../_shared/credentials.ts";
import { realClock } from "../_shared/resilience.ts";
import {
  SupabaseBreakerStore,
  SupabaseHealthStore,
  SupabaseRateLimitStore,
  SupabaseUsageStore,
  SupabaseUserSettingsStore,
} from "../_shared/supabase_stores.ts";
import { createStatusHandler } from "./handler.ts";

Deno.serve((req) => {
  const db = serviceClient(denoEnv);
  const handler = createStatusHandler({
    env: denoEnv,
    authenticate: (r) => getUser(r, denoEnv),
    rateLimits: new SupabaseRateLimitStore(db),
    usage: new SupabaseUsageStore(db),
    userSettings: new SupabaseUserSettingsStore(db),
    health: new SupabaseHealthStore(db),
    breakerStore: new SupabaseBreakerStore(db),
    fetchFn: fetch,
    clock: realClock,
    log: (e) => console.log(JSON.stringify(e)),
  });
  return handler(req);
});
