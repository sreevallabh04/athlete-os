import { assert, assertEquals } from "jsr:@std/assert@1";
import { InMemoryRateLimitStore, type RateLimitStore } from "../_shared/ratelimit.ts";
import {
  createStravaHandler,
  DEFAULT_STRAVA_RATE_LIMIT_PER_MIN,
  STRAVA_RATE_LIMIT_BUCKET,
  type StravaBackend,
  type TokenRow,
} from "./handler.ts";

const T0 = Date.UTC(2026, 9, 26, 12, 0, 20); // 20 s into the minute
const FAR_FUTURE = new Date(T0 + 6 * 3600_000).toISOString();

const baseEnv: Record<string, string> = {
  STRAVA_CLIENT_ID: "cid",
  STRAVA_CLIENT_SECRET: "secret",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service",
};

interface Harness {
  handler: (req: Request) => Promise<Response>;
  fetchCalls: string[];
  authCalls: number;
  limits: InMemoryRateLimitStore;
  global: InMemoryRateLimitStore;
  clock: { t: number };
}

function harness(opts: {
  env?: Record<string, string>;
  users?: Record<string, string>;
  rows?: TokenRow[];
  rateLimits?: RateLimitStore;
} = {}): Harness {
  const env = { ...baseEnv, ...(opts.env ?? {}) };
  const users = opts.users ?? { "jwt-a": "user-a", "jwt-b": "user-b" };
  const rows = new Map((opts.rows ?? []).map((r) => [r.user_id, r]));
  const limits = new InMemoryRateLimitStore();
  const global = new InMemoryRateLimitStore();
  const fetchCalls: string[] = [];
  const clock = { t: T0 };
  const h: Harness = {
    handler: () => Promise.reject(new Error("unset")),
    fetchCalls,
    authCalls: 0,
    limits,
    global,
    clock,
  };
  const backend: StravaBackend = {
    getUserId: (jwt) => {
      h.authCalls++;
      return Promise.resolve(users[jwt] ?? null);
    },
    loadTokens: (userId) => Promise.resolve(rows.get(userId) ?? null),
    saveTokens: (row) => {
      rows.set(row.user_id, row);
      return Promise.resolve();
    },
    deleteTokens: (userId) => {
      rows.delete(userId);
      return Promise.resolve();
    },
    rateLimits: opts.rateLimits ?? limits,
  };
  h.handler = createStravaHandler({
    env: (n) => env[n],
    backend: () => backend,
    fetchFn: (input) => {
      fetchCalls.push(String(input));
      return Promise.resolve(new Response("{}", { status: 500 }));
    },
    now: () => clock.t,
    globalLimits: global,
  });
  return h;
}

const row = (userId: string): TokenRow => ({
  user_id: userId,
  athlete_id: 42,
  refresh_token: "r",
  access_token: "a",
  expires_at: FAR_FUTURE,
  scope: "read,activity:read_all",
});

const refresh = (jwt = "jwt-a") =>
  new Request("https://fn/strava-oauth", {
    method: "POST",
    headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
    body: JSON.stringify({ action: "refresh" }),
  });

Deno.test("strava-oauth: per-user limit -> 429 with Retry-After, Strava never called", async () => {
  const h = harness({ rows: [row("user-a"), row("user-b")] });
  for (let i = 0; i < DEFAULT_STRAVA_RATE_LIMIT_PER_MIN; i++) {
    const ok = await h.handler(refresh());
    assertEquals(ok.status, 200);
    await ok.body?.cancel();
  }
  const denied = await h.handler(refresh());
  assertEquals(denied.status, 429);
  assertEquals(denied.headers.get("Retry-After"), "40");
  assertEquals((await denied.json()).error, "rate_limited");
  // Fresh tokens: nothing was forwarded to Strava at all.
  assertEquals(h.fetchCalls, []);
  // The counter lives in the strava-oauth bucket, keyed by user.
  assert([...h.limits.counts.keys()].every((k) => k.startsWith("user-a|strava-oauth|")));

  // Another user is unaffected; the next window resets.
  const other = await h.handler(refresh("jwt-b"));
  assertEquals(other.status, 200);
  await other.body?.cancel();
  h.clock.t = T0 + 40_000;
  const next = await h.handler(refresh());
  assertEquals(next.status, 200);
  await next.body?.cancel();
});

Deno.test("strava-oauth: limited requests never reach the token endpoint", async () => {
  const h = harness({ env: { STRAVA_RATE_LIMIT_PER_MIN: "1" } });
  const exchange = () =>
    new Request("https://fn/strava-oauth", {
      method: "POST",
      headers: { Authorization: "Bearer jwt-a" },
      body: JSON.stringify({
        action: "exchange",
        code: "abc",
        redirect_uri: "athleteos://localhost/strava",
        scope: "activity:read_all",
      }),
    });
  const first = await h.handler(exchange());
  await first.body?.cancel();
  assertEquals(h.fetchCalls.length, 1); // first one hit Strava (fake 500 -> 502)
  const second = await h.handler(exchange());
  assertEquals(second.status, 429);
  await second.body?.cancel();
  assertEquals(h.fetchCalls.length, 1);
});

Deno.test("strava-oauth: invalid sessions are rejected before counting", async () => {
  const h = harness();
  for (let i = 0; i < 3; i++) {
    const r = await h.handler(refresh("forged"));
    assertEquals(r.status, 401);
    await r.body?.cancel();
  }
  assertEquals(h.limits.counts.size, 0);
});

Deno.test("strava-oauth: global per-instance cap -> 429 before auth", async () => {
  const h = harness({
    env: { STRAVA_GLOBAL_RATE_LIMIT_PER_MIN: "3" },
    rows: [row("user-a"), row("user-b")],
  });
  for (const jwt of ["jwt-a", "jwt-b", "jwt-a"]) {
    const r = await h.handler(refresh(jwt));
    assertEquals(r.status, 200);
    await r.body?.cancel();
  }
  const authBefore = h.authCalls;
  const denied = await h.handler(refresh("jwt-b"));
  assertEquals(denied.status, 429);
  assertEquals(denied.headers.get("Retry-After"), "40");
  await denied.body?.cancel();
  assertEquals(h.authCalls, authBefore);
  assert([...h.global.counts.keys()].every((k) => k.includes(`|${STRAVA_RATE_LIMIT_BUCKET}|`)));
});

Deno.test("strava-oauth: limiter failure fails closed with 503", async () => {
  const h = harness({
    rows: [row("user-a")],
    rateLimits: { increment: () => Promise.reject(new Error("db down")) },
  });
  const r = await h.handler(refresh());
  assertEquals(r.status, 503);
  assertEquals(r.headers.get("Retry-After"), "5");
  assertEquals((await r.json()).error, "rate_limit_unavailable");
  assertEquals(h.fetchCalls, []);
});

Deno.test("strava-oauth: refresh still returns only public token fields", async () => {
  const h = harness({ rows: [row("user-a")] });
  const r = await h.handler(refresh());
  assertEquals(r.status, 200);
  const body = await r.json();
  assertEquals(Object.keys(body).sort(), ["access_token", "athlete_id", "expires_at", "scope"]);
  assertEquals(body.refresh_token, undefined);
});

Deno.test("strava-oauth: OPTIONS / GET are not rate limited", async () => {
  const h = harness({ env: { STRAVA_GLOBAL_RATE_LIMIT_PER_MIN: "1" } });
  for (let i = 0; i < 3; i++) {
    const r = await h.handler(new Request("https://fn/strava-oauth", { method: "OPTIONS" }));
    assertEquals(r.status, 200);
    await r.body?.cancel();
  }
  const g = await h.handler(new Request("https://fn/strava-oauth"));
  assertEquals(g.status, 405);
  await g.body?.cancel();
  assertEquals(h.global.counts.size, 0);
});
