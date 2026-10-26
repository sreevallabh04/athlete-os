// strava-oauth request handler with injectable dependencies (wired with the
// real Supabase client in index.ts, with fakes in handler_test.ts).
//
// Keeps the Strava client secret and refresh tokens server-side. Only
// short-lived access tokens are ever returned to the client. Refresh tokens,
// the client secret and access tokens are never logged.
import type { EnvFn } from "../_shared/providers/types.ts";
import {
  checkRateLimit,
  GLOBAL_RATE_LIMIT_KEY,
  InMemoryRateLimitStore,
  limitFromEnv,
  type RateLimitResult,
  type RateLimitStore,
} from "../_shared/ratelimit.ts";
import { readStravaRequest } from "./request.ts";

const STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token";
// Revocation endpoint (Strava docs, Oct 2026). Older docs name
// /oauth/deauthorize, used as a fallback if /oauth/revoke is not found.
const STRAVA_REVOKE_URL = "https://www.strava.com/oauth/revoke";
const STRAVA_DEAUTHORIZE_URL = "https://www.strava.com/oauth/deauthorize";
const STRAVA_PROBE_URL = "https://www.strava.com/api/v3/athlete/activities?per_page=1";
const REFRESH_MARGIN_SECONDS = 10 * 60;

/** Rate-limit bucket in api_rate_limits. */
export const STRAVA_RATE_LIMIT_BUCKET = "strava-oauth";
/** Per signed-in user (anonymous sign-ups make accounts cheap to create). */
export const DEFAULT_STRAVA_RATE_LIMIT_PER_MIN = 10;
/**
 * Sanity cap per function instance (isolate), across all users. Best-effort:
 * each isolate counts on its own, but it bounds what one warm instance will
 * forward to Supabase Auth and Strava while being hammered.
 */
export const DEFAULT_STRAVA_GLOBAL_RATE_LIMIT_PER_MIN = 300;

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...extra },
  });
}

const fail = (status: number, error: string, message?: string, extra?: Record<string, string>) =>
  json(status, message ? { error, message } : { error }, extra);

/** Thrown to short-circuit with a ready-made error response. */
class HttpError extends Error {
  constructor(public response: Response) {
    super("http_error");
  }
}

export type TokenRow = {
  user_id: string;
  athlete_id: number;
  refresh_token: string;
  access_token: string | null;
  expires_at: string | null;
  scope: string | null;
};

/** Server-side persistence + auth (service role). Methods throw on DB errors. */
export interface StravaBackend {
  /** The signed-in user's id for [jwt], or null when it is not a valid session. */
  getUserId(jwt: string): Promise<string | null>;
  loadTokens(userId: string): Promise<TokenRow | null>;
  saveTokens(row: TokenRow): Promise<void>;
  deleteTokens(userId: string): Promise<void>;
  rateLimits: RateLimitStore;
}

export interface StravaDeps {
  env: EnvFn;
  /** Created once Supabase env is known to be present. */
  backend: (supabaseUrl: string, serviceKey: string) => StravaBackend;
  fetchFn: typeof fetch;
  now: () => number;
  /** Process-wide counters for the global sanity cap. */
  globalLimits: RateLimitStore;
}

const toEpoch = (iso: string | null) => (iso ? Math.floor(Date.parse(iso) / 1000) : 0);

/** The only shape ever returned on success for exchange/refresh. */
const publicTokens = (row: TokenRow) => ({
  access_token: row.access_token,
  expires_at: toEpoch(row.expires_at),
  athlete_id: Number(row.athlete_id),
  scope: row.scope,
});

/** Maps a non-OK Strava response to a safe client error (never echoes the body). */
function stravaError(res: Response): Response {
  if (res.status === 429) {
    const retry = res.headers.get("Retry-After");
    return fail(
      429,
      "rate_limited",
      "Strava rate limit reached. Try again later.",
      retry ? { "Retry-After": retry } : {},
    );
  }
  return fail(502, "strava_error", `Strava responded with HTTP ${res.status}.`);
}

const tooMany = (rl: RateLimitResult, message: string) =>
  fail(429, "rate_limited", message, { "Retry-After": String(rl.retryAfterS) });

export function createStravaHandler(deps: StravaDeps): (req: Request) => Promise<Response> {
  const { env, fetchFn } = deps;

  /** POSTs form-encoded params to Strava's token endpoint. */
  async function postToken(params: Record<string, string>): Promise<Response> {
    try {
      return await fetchFn(STRAVA_TOKEN_URL, { method: "POST", body: new URLSearchParams(params) });
    } catch {
      throw new HttpError(fail(502, "upstream_unavailable", "Could not reach Strava."));
    }
  }

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (req.method !== "POST") return fail(405, "method_not_allowed");

    try {
      const clientId = env("STRAVA_CLIENT_ID");
      const clientSecret = env("STRAVA_CLIENT_SECRET");
      const supabaseUrl = env("SUPABASE_URL");
      const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
      if (!clientId || !clientSecret) {
        // Code kept stable for the app (StravaAuth maps it to "awaiting credentials").
        return fail(
          500,
          "server_not_configured",
          "Strava is not configured on the server (STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET are unset).",
        );
      }
      if (!supabaseUrl || !serviceKey) {
        return fail(500, "server_not_configured", "Supabase environment is incomplete.");
      }
      const allowedRedirect = env("STRAVA_ALLOWED_REDIRECT") ?? "athleteos://localhost/strava";

      // --- Global sanity cap (in-memory, before any auth/DB/Strava call).
      const global = await checkRateLimit(
        deps.globalLimits,
        GLOBAL_RATE_LIMIT_KEY,
        STRAVA_RATE_LIMIT_BUCKET,
        limitFromEnv(env, "STRAVA_GLOBAL_RATE_LIMIT_PER_MIN", DEFAULT_STRAVA_GLOBAL_RATE_LIMIT_PER_MIN),
        deps.now(),
      );
      if (!global.allowed) return tooMany(global, "Strava sync is busy. Try again shortly.");

      const backend = deps.backend(supabaseUrl, serviceKey);

      // --- Authenticate: a real signed-in user is required (the anon key has no user).
      const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
      if (!jwt) return fail(401, "unauthorized", "Missing bearer token.");
      const userId = await backend.getUserId(jwt).catch(() => null);
      if (!userId) return fail(401, "unauthorized", "Sign in required.");

      // --- Per-user rate limit (anonymous sign-ups make accounts cheap).
      let perUser: RateLimitResult;
      try {
        perUser = await checkRateLimit(
          backend.rateLimits,
          userId,
          STRAVA_RATE_LIMIT_BUCKET,
          limitFromEnv(env, "STRAVA_RATE_LIMIT_PER_MIN", DEFAULT_STRAVA_RATE_LIMIT_PER_MIN),
          deps.now(),
        );
      } catch {
        // Fail closed: without a working limiter we do not forward to Strava.
        return fail(503, "rate_limit_unavailable", "Try again shortly.", { "Retry-After": "5" });
      }
      if (!perUser.allowed) return tooMany(perUser, "Too many Strava requests. Please wait a moment.");

      // Byte-capped read + strict shape/type checks (a null/array body or a
      // non-string code/scope used to surface as a 500).
      const parsed = await readStravaRequest(req, allowedRedirect);
      if (!parsed.ok) return fail(parsed.status, parsed.error, parsed.message);
      const body = parsed.value;

      const db = <T>(op: () => Promise<T>): Promise<T> =>
        op().catch(() => {
          throw new HttpError(fail(500, "db_error"));
        });
      const loadRow = () => db(() => backend.loadTokens(userId));
      const deleteRow = () => db(() => backend.deleteTokens(userId));
      const saveRow = (row: TokenRow) => db(() => backend.saveTokens(row));

      /** Returns a row whose access token is valid for > 10 min, refreshing if needed. */
      const ensureFresh = async (row: TokenRow): Promise<TokenRow> => {
        const now = Math.floor(deps.now() / 1000);
        if (row.access_token && toEpoch(row.expires_at) - now > REFRESH_MARGIN_SECONDS) return row;
        const res = await postToken({
          client_id: clientId,
          client_secret: clientSecret,
          grant_type: "refresh_token",
          refresh_token: row.refresh_token,
        });
        if (res.status === 400 || res.status === 401) {
          // Refresh token revoked/invalid: forget it so the app re-runs OAuth.
          await deleteRow();
          throw new HttpError(
            fail(401, "reauthorize_required", "Strava access was revoked. Reconnect Strava."),
          );
        }
        if (!res.ok) throw new HttpError(stravaError(res));
        const t = await res.json();
        // Strava may rotate the refresh token: always persist the latest one.
        const updated: TokenRow = {
          ...row,
          access_token: t.access_token,
          refresh_token: t.refresh_token ?? row.refresh_token,
          expires_at: new Date(Number(t.expires_at) * 1000).toISOString(),
        };
        await saveRow(updated);
        return updated;
      };

      switch (body.action) {
        case "exchange": {
          // code / redirect_uri allowlist / scope already validated by parseStravaRequest.
          const res = await postToken({
            client_id: clientId,
            client_secret: clientSecret,
            code: body.code,
            grant_type: "authorization_code",
          });
          if (res.status === 400 || res.status === 401) {
            return fail(400, "invalid_code", "Authorization code was rejected or expired.");
          }
          if (!res.ok) return stravaError(res);
          const t = await res.json();
          if (!t?.athlete?.id || !t.refresh_token) {
            return fail(502, "strava_error", "Unexpected token response.");
          }

          // Strava reports granted scopes on the redirect (?scope=...), not always in
          // the token response, so the client forwards it. If neither is present,
          // probe an activity endpoint that requires activity:read.
          let scope: string | null = t.scope ?? body.scope ?? null;
          if (!scope) {
            const probe = await fetchFn(STRAVA_PROBE_URL, {
              headers: { Authorization: `Bearer ${t.access_token}` },
            }).catch(() => null);
            scope = probe?.ok ? "activity:read" : null;
          }
          const scopes = (scope ?? "").split(/[,\s]+/);
          if (!scopes.includes("activity:read_all") && !scopes.includes("activity:read")) {
            return fail(400, "insufficient_scope", "Activity access was not granted.");
          }
          const row: TokenRow = {
            user_id: userId,
            athlete_id: Number(t.athlete.id),
            refresh_token: t.refresh_token,
            access_token: t.access_token,
            expires_at: new Date(Number(t.expires_at) * 1000).toISOString(),
            scope,
          };
          await saveRow(row);
          return json(200, publicTokens(row));
        }

        case "refresh": {
          const row = await loadRow();
          if (!row) return fail(404, "not_connected");
          return json(200, publicTokens(await ensureFresh(row)));
        }

        case "revoke": {
          const row = await loadRow();
          if (row) {
            // Best effort: Strava errors (incl. an already-revoked token) are ignored.
            try {
              const fresh = await ensureFresh(row);
              const form = () => new URLSearchParams({ access_token: fresh.access_token ?? "" });
              const res = await fetchFn(STRAVA_REVOKE_URL, { method: "POST", body: form() });
              if (res.status === 404) {
                await fetchFn(STRAVA_DEAUTHORIZE_URL, { method: "POST", body: form() });
              }
            } catch { /* ignore */ }
            await deleteRow();
          }
          return json(200, { revoked: true });
        }

        default:
          return fail(400, "invalid_action", "action must be exchange, refresh or revoke.");
      }
    } catch (e) {
      if (e instanceof HttpError) return e.response;
      // Log only the error type, never request bodies or tokens.
      console.error("strava-oauth unexpected error:", e instanceof Error ? e.name : "unknown");
      return fail(500, "internal_error");
    }
  };
}

/** One per isolate: the global cap counts across requests served by it. */
export const isolateGlobalLimits = new InMemoryRateLimitStore();
