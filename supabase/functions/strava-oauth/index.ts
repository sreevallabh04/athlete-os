// Supabase Edge Function: strava-oauth
//
// Keeps the Strava client secret and refresh tokens server-side. The Athlete OS
// app calls this function (with the signed-in user's Supabase JWT) to:
//   - exchange: swap an OAuth authorization code for tokens
//   - refresh:  get a valid (<= 6 h) access token, refreshing when needed
//   - revoke:   deauthorize the app on Strava and forget the stored tokens
//
// Only short-lived access tokens are ever returned to the client. Refresh
// tokens, the client secret and access tokens are never logged.
//
// Rate limited per user (STRAVA_RATE_LIMIT_PER_MIN, default 10/min, bucket
// "strava-oauth" in api_rate_limits) and per instance across all users
// (STRAVA_GLOBAL_RATE_LIMIT_PER_MIN, default 300/min); 429 + Retry-After.
// Logic lives in handler.ts (tested in handler_test.ts).
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (provided by Supabase),
//      STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET (set via `supabase secrets set`),
//      STRAVA_ALLOWED_REDIRECT (optional, default athleteos://localhost/strava).
// Pinned like the other functions (an unpinned `@2` resolves to whatever is
// latest at deploy time).
import { createClient } from "npm:@supabase/supabase-js@2.75.0";
import { denoEnv } from "../_shared/credentials.ts";
import { SupabaseRateLimitStore } from "../_shared/supabase_stores.ts";
import { createStravaHandler, isolateGlobalLimits, type StravaBackend, type TokenRow } from "./handler.ts";

function supabaseBackend(supabaseUrl: string, serviceKey: string): StravaBackend {
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return {
    async getUserId(jwt) {
      const { data, error } = await admin.auth.getUser(jwt);
      return error || !data?.user ? null : data.user.id;
    },
    async loadTokens(userId) {
      const { data, error } = await admin.from("strava_tokens").select("*")
        .eq("user_id", userId).maybeSingle();
      if (error) throw new Error("db_error");
      return data as TokenRow | null;
    },
    async saveTokens(row) {
      const { error } = await admin.from("strava_tokens")
        .upsert({ ...row, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
      if (error) throw new Error("db_error");
    },
    async deleteTokens(userId) {
      const { error } = await admin.from("strava_tokens").delete().eq("user_id", userId);
      if (error) throw new Error("db_error");
    },
    rateLimits: new SupabaseRateLimitStore(admin),
  };
}

const handler = createStravaHandler({
  env: denoEnv,
  backend: supabaseBackend,
  fetchFn: fetch,
  now: () => Date.now(),
  globalLimits: isolateGlobalLimits,
});

Deno.serve(handler);
