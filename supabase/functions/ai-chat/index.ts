// Supabase Edge Function entrypoint: POST /functions/v1/ai-chat
import { getUser, serviceClient } from "../_shared/auth.ts";
import { denoEnv } from "../_shared/credentials.ts";
import { realClock } from "../_shared/resilience.ts";
import {
  SupabaseBreakerStore,
  SupabaseHealthStore,
  SupabaseRateLimitStore,
  SupabaseResponseCache,
  SupabaseUsageStore,
  SupabaseUserSettingsStore,
} from "../_shared/supabase_stores.ts";
import { createChatHandler } from "./handler.ts";

Deno.serve((req) => {
  const db = serviceClient(denoEnv);
  const handler = createChatHandler({
    env: denoEnv,
    authenticate: (r) => getUser(r, denoEnv),
    cache: new SupabaseResponseCache(db),
    rateLimits: new SupabaseRateLimitStore(db),
    usage: new SupabaseUsageStore(db),
    userSettings: new SupabaseUserSettingsStore(db),
    // Per-request instances: their small read caches must not leak across requests.
    health: new SupabaseHealthStore(db),
    breakerStore: new SupabaseBreakerStore(db),
    fetchFn: fetch,
    clock: realClock,
    // Structured logs only: request_id / provider / alias / status / latency.
    log: (e) => console.log(JSON.stringify(e)),
  });
  return handler(req);
});
