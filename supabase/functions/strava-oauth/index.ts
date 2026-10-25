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
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (provided by Supabase),
//      STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET (set via `supabase secrets set`),
//      STRAVA_ALLOWED_REDIRECT (optional, default athleteos://localhost/strava).
// Pinned like the other functions (an unpinned `@2` resolves to whatever is
// latest at deploy time).
import { createClient } from "npm:@supabase/supabase-js@2.75.0";
import { readStravaRequest } from "./request.ts";

const STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token";
// Revocation endpoint (Strava docs, Oct 2026). Older docs name
// /oauth/deauthorize, used as a fallback if /oauth/revoke is not found.
const STRAVA_REVOKE_URL = "https://www.strava.com/oauth/revoke";
const STRAVA_DEAUTHORIZE_URL = "https://www.strava.com/oauth/deauthorize";
const STRAVA_PROBE_URL = "https://www.strava.com/api/v3/athlete/activities?per_page=1";
const REFRESH_MARGIN_SECONDS = 10 * 60;

const corsHeaders = {
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

type TokenRow = {
  user_id: string;
  athlete_id: number;
  refresh_token: string;
  access_token: string | null;
  expires_at: string | null;
  scope: string | null;
};

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
    return fail(429, "rate_limited", "Strava rate limit reached. Try again later.",
      retry ? { "Retry-After": retry } : {});
  }
  return fail(502, "strava_error", `Strava responded with HTTP ${res.status}.`);
}

/** POSTs form-encoded params to Strava's token endpoint. */
async function postToken(params: Record<string, string>): Promise<Response> {
  try {
    return await fetch(STRAVA_TOKEN_URL, { method: "POST", body: new URLSearchParams(params) });
  } catch {
    throw new HttpError(fail(502, "upstream_unavailable", "Could not reach Strava."));
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "method_not_allowed");

  try {
    const clientId = Deno.env.get("STRAVA_CLIENT_ID");
    const clientSecret = Deno.env.get("STRAVA_CLIENT_SECRET");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
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
    const allowedRedirect = Deno.env.get("STRAVA_ALLOWED_REDIRECT") ?? "athleteos://localhost/strava";

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // --- Authenticate: a real signed-in user is required (the anon key has no user).
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!jwt) return fail(401, "unauthorized", "Missing bearer token.");
    const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
    if (userErr || !userData?.user) return fail(401, "unauthorized", "Sign in required.");
    const userId = userData.user.id;

    // Byte-capped read + strict shape/type checks (a null/array body or a
    // non-string code/scope used to surface as a 500).
    const parsed = await readStravaRequest(req, allowedRedirect);
    if (!parsed.ok) return fail(parsed.status, parsed.error, parsed.message);
    const body = parsed.value;

    const loadRow = async (): Promise<TokenRow | null> => {
      const { data, error } = await admin.from("strava_tokens").select("*")
        .eq("user_id", userId).maybeSingle();
      if (error) throw new HttpError(fail(500, "db_error"));
      return data as TokenRow | null;
    };
    const deleteRow = async () => {
      const { error } = await admin.from("strava_tokens").delete().eq("user_id", userId);
      if (error) throw new HttpError(fail(500, "db_error"));
    };
    const saveRow = async (row: TokenRow) => {
      const { error } = await admin.from("strava_tokens")
        .upsert({ ...row, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
      if (error) throw new HttpError(fail(500, "db_error"));
    };

    /** Returns a row whose access token is valid for > 10 min, refreshing if needed. */
    const ensureFresh = async (row: TokenRow): Promise<TokenRow> => {
      const now = Math.floor(Date.now() / 1000);
      if (row.access_token && toEpoch(row.expires_at) - now > REFRESH_MARGIN_SECONDS) return row;
      const res = await postToken({
        client_id: clientId, client_secret: clientSecret,
        grant_type: "refresh_token", refresh_token: row.refresh_token,
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
          client_id: clientId, client_secret: clientSecret,
          code: body.code, grant_type: "authorization_code",
        });
        if (res.status === 400 || res.status === 401) {
          return fail(400, "invalid_code", "Authorization code was rejected or expired.");
        }
        if (!res.ok) return stravaError(res);
        const t = await res.json();
        if (!t?.athlete?.id || !t.refresh_token) return fail(502, "strava_error", "Unexpected token response.");

        // Strava reports granted scopes on the redirect (?scope=...), not always in
        // the token response, so the client forwards it. If neither is present,
        // probe an activity endpoint that requires activity:read.
        let scope: string | null = t.scope ?? body.scope ?? null;
        if (!scope) {
          const probe = await fetch(STRAVA_PROBE_URL, {
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
            const res = await fetch(STRAVA_REVOKE_URL, { method: "POST", body: form() });
            if (res.status === 404) {
              await fetch(STRAVA_DEAUTHORIZE_URL, { method: "POST", body: form() });
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
});
