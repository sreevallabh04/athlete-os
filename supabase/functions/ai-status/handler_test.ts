import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { createStatusHandler, type StatusDeps } from "./handler.ts";
import { InMemoryRateLimitStore } from "../_shared/ratelimit.ts";
import { InMemoryBreakerStore, InMemoryHealthStore } from "../_shared/resilience.ts";
import { InMemoryUsageStore, InMemoryUserSettingsStore } from "../_shared/stores.ts";

const KEY = "sk-ant-api03-STATUSKEYSTATUSKEY";

function setup(
  env: Record<string, string> = { ANTHROPIC_API_KEY: KEY, GEMINI_API_KEY: "AIzaSTATUSKEYSTATUSKEYSTATUS" },
) {
  const t = Date.UTC(2026, 9, 25, 12);
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const deps: StatusDeps = {
    env: (n) => env[n],
    authenticate: (req) =>
      req.headers.get("Authorization") ? Promise.resolve("user-1") : Promise.reject(new Error("no")),
    rateLimits: new InMemoryRateLimitStore(),
    usage: new InMemoryUsageStore(() => t),
    userSettings: new InMemoryUserSettingsStore(),
    health: new InMemoryHealthStore(),
    breakerStore: new InMemoryBreakerStore(),
    fetchFn: ((url: string | URL | Request, init?: RequestInit) => {
      const u = String(url);
      calls.push({ url: u, body: JSON.parse(String(init?.body)) });
      if (u.includes("anthropic")) {
        return Promise.resolve(
          new Response(JSON.stringify({
            content: [{ type: "text", text: "OK" }],
            stop_reason: "end_turn",
            usage: { input_tokens: 10, output_tokens: 2 },
          })),
        );
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            error: {
              code: 400,
              status: "INVALID_ARGUMENT",
              message: "API key not valid.",
              details: [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "API_KEY_INVALID" }],
            },
          }),
          { status: 400 },
        ),
      );
    }) as typeof fetch,
    clock: { now: () => t, sleep: () => Promise.resolve(), random: () => 0.5 },
    log: () => {},
    randomId: (() => {
      let i = 0;
      return () => `id${i++}`;
    })(),
  };
  return { deps, handler: createStatusHandler(deps), calls };
}

const auth = { Authorization: "Bearer jwt" };

Deno.test("ai-status: requires auth", async () => {
  const { handler } = setup();
  const r = await handler(new Request("http://x", { method: "GET" }));
  assertEquals(r.status, 401);
});

Deno.test("ai-status: status shape without key material", async () => {
  const { handler, deps } = setup();
  await deps.health.markFailure(
    "gemini",
    "primary",
    "quota_exhausted",
    new Date(Date.UTC(2026, 9, 25, 13)),
    `quota ${KEY}`,
  );
  await deps.usage.record({
    user_id: "user-1",
    request_id: "r1",
    provider: "anthropic",
    model: "claude-sonnet-5-5",
    credential_alias: "primary",
    input_tokens: 100,
    output_tokens: 10,
    cost_usd: 6,
    status: "ok",
    latency_ms: 5,
  });
  const r = await handler(new Request("http://x", { method: "GET", headers: auth }));
  assertEquals(r.status, 200);
  const text = await r.text();
  assertFalse(text.includes("STATUSKEY"));
  const j = JSON.parse(text);
  assertEquals(j.provider_order, ["anthropic", "openai", "gemini", "groq"]);
  assertEquals(j.limits, {
    max_tokens: [256, 16000],
    timeout_ms: [5000, 120000],
    max_retries: [0, 2],
    rate_limit_per_min: 30,
  });
  const anth = j.providers.find((p: { provider: string }) => p.provider === "anthropic");
  assertEquals(anth.configured, true);
  assertEquals(anth.default_model, "claude-sonnet-5-5");
  assertEquals(anth.circuit, "closed");
  assert(anth.allowed_models.includes("claude-haiku-5-5"));
  assertEquals(anth.aliases, [{
    alias: "primary",
    status: "ok",
    cooldown_until: null,
    consecutive_failures: 0,
    last_error: null,
  }]);
  const openai = j.providers.find((p: { provider: string }) => p.provider === "openai");
  assertEquals(openai.configured, false);
  assertEquals(openai.aliases, []);
  const gem = j.providers.find((p: { provider: string }) => p.provider === "gemini");
  assertEquals(gem.aliases[0].status, "quota_exhausted");
  assertEquals(gem.aliases[0].consecutive_failures, 1);
  assertEquals(j.usage, {
    month_start: "2026-10-01",
    requests: 1,
    input_tokens: 100,
    output_tokens: 10,
    cost_usd: 6,
    monthly_budget_usd: 10,
    global_budget_usd: 10,
    percent: 60,
    alerts: [50],
  });
  // POST {action:"status"} is equivalent
  const p = await handler(
    new Request("http://x", { method: "POST", headers: auth, body: JSON.stringify({ action: "status" }) }),
  );
  assertEquals(p.status, 200);
});

Deno.test("ai-status: test action calls each credential with cheapest model and updates health", async () => {
  const { handler, deps, calls } = setup();
  const r = await handler(
    new Request("http://x", { method: "POST", headers: auth, body: JSON.stringify({ action: "test" }) }),
  );
  assertEquals(r.status, 200);
  const text = await r.text();
  assertFalse(text.includes("STATUSKEY"));
  const { results } = JSON.parse(text);
  assertEquals(results.length, 2);
  const a = results.find((x: { provider: string }) => x.provider === "anthropic");
  assertEquals(a.ok, true);
  assertEquals(a.model, "claude-haiku-5-5");
  assertEquals(a.error, null);
  assertEquals(a.alias, "primary");
  const g = results.find((x: { provider: string }) => x.provider === "gemini");
  assertEquals(g.ok, false);
  assert(g.error.includes("API key not valid"));
  const anthCall = calls.find((c) => c.url.includes("anthropic"))!;
  assertEquals(anthCall.body.max_tokens, 16);
  assertFalse("tools" in anthCall.body);
  assertEquals((await deps.health.get("gemini", "primary"))?.status, "invalid");
  assertEquals((await deps.health.get("anthropic", "primary"))?.status, "ok");
  assertEquals((deps.usage as InMemoryUsageStore).rows.size, 2);
});

Deno.test("ai-status: test action filtered by provider and rate limited to 5/min", async () => {
  const { handler, calls } = setup();
  const req = () =>
    new Request("http://x", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ action: "test", provider: "anthropic" }),
    });
  const first = await (await handler(req())).json();
  assertEquals(first.results.length, 1);
  assertEquals(calls.length, 1);
  for (let i = 0; i < 4; i++) assertEquals((await handler(req())).status, 200);
  const limited = await handler(req());
  assertEquals(limited.status, 429);
  assert((await limited.json()).error.retry_after_s > 0);
});

Deno.test("ai-status: invalid action / provider -> 400", async () => {
  const { handler } = setup();
  const a = await handler(
    new Request("http://x", { method: "POST", headers: auth, body: JSON.stringify({ action: "nuke" }) }),
  );
  assertEquals(a.status, 400);
  const b = await handler(
    new Request("http://x", { method: "POST", headers: auth, body: JSON.stringify({ action: "test", provider: "x" }) }),
  );
  assertEquals(b.status, 400);
});
