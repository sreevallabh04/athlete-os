import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { buildPlan, type ChatDeps, createChatHandler } from "./handler.ts";
import { InMemoryRateLimitStore } from "../_shared/ratelimit.ts";
import { type Clock, InMemoryBreakerStore, InMemoryHealthStore } from "../_shared/resilience.ts";
import { InMemoryResponseCache, InMemoryUsageStore, InMemoryUserSettingsStore } from "../_shared/stores.ts";
import { loadCredentials } from "../_shared/credentials.ts";
import { loadPriceTable } from "../_shared/budget.ts";
import { WEATHER_TOOL } from "../_shared/testing.ts";

const ANTHROPIC_KEY = "sk-ant-api03-TESTKEYTESTKEYTESTKEY";
const OPENAI_KEY = "sk-proj-TESTKEYTESTKEYTESTKEY";

const anthropicOk = () =>
  new Response(JSON.stringify({
    content: [
      { type: "thinking", thinking: "t", signature: "s" },
      { type: "text", text: "Logged!" },
      { type: "tool_use", id: "toolu_1", name: "log_water", input: { amount_ml: 500 } },
    ],
    stop_reason: "tool_use",
    usage: { input_tokens: 1000, output_tokens: 100 },
  }));
const openaiOk = () =>
  new Response(JSON.stringify({
    status: "completed",
    output: [{ type: "message", content: [{ type: "output_text", text: "Hi from OpenAI" }] }],
    usage: { input_tokens: 2000, output_tokens: 200 },
  }));

type Route = () => Response;

function setup(opts: {
  env?: Record<string, string>;
  anthropic?: Route[];
  openai?: Route[];
  userId?: string | null;
} = {}) {
  const env: Record<string, string> = {
    ANTHROPIC_API_KEY: ANTHROPIC_KEY,
    OPENAI_API_KEY: OPENAI_KEY,
    ...(opts.env ?? {}),
  };
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const queues: Record<string, Route[]> = {
    anthropic: opts.anthropic ?? [anthropicOk],
    openai: opts.openai ?? [openaiOk],
  };
  const fetchFn = ((url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, body: JSON.parse(String(init?.body)) });
    const q = u.includes("anthropic") ? queues.anthropic : queues.openai;
    const route = q.length > 1 ? q.shift()! : q[0];
    return Promise.resolve(route());
  }) as typeof fetch;
  const clock: Clock & { t: number } = {
    t: Date.UTC(2026, 9, 25, 12, 0, 0),
    now: () => clock.t,
    sleep: (ms: number) => {
      clock.t += ms;
      return Promise.resolve();
    },
    random: () => 0.5,
  };
  const logs: Record<string, unknown>[] = [];
  const deps: ChatDeps = {
    env: (n) => env[n],
    authenticate: (req) => {
      if (opts.userId === null || !req.headers.get("Authorization")) return Promise.reject(new Error("no"));
      return Promise.resolve(opts.userId ?? "user-1");
    },
    cache: new InMemoryResponseCache(() => clock.t),
    rateLimits: new InMemoryRateLimitStore(),
    usage: new InMemoryUsageStore(() => clock.t),
    userSettings: new InMemoryUserSettingsStore(),
    health: new InMemoryHealthStore(),
    breakerStore: new InMemoryBreakerStore(),
    fetchFn,
    clock,
    log: (e) => logs.push(e),
  };
  return { deps, handler: createChatHandler(deps), calls, logs, clock };
}

function body(over: Record<string, unknown> = {}) {
  return {
    request_id: "req_abcdef123",
    conversation_id: "conv-1",
    system: "You are a coach.",
    messages: [{ role: "user", content: [{ type: "text", text: "Log water" }] }],
    tools: [WEATHER_TOOL],
    preferences: {
      primary_provider: null,
      model: null,
      fallback_providers: [],
      max_tokens: 4096,
      timeout_ms: 60000,
      max_retries: 2,
      monthly_budget_usd: 10,
    },
    ...over,
  };
}

const post = (b: unknown, headers: Record<string, string> = { Authorization: "Bearer jwt" }) =>
  new Request("http://localhost/functions/v1/ai-chat", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof b === "string" ? b : JSON.stringify(b),
  });

Deno.test("ai-chat: OPTIONS preflight and method check", async () => {
  const { handler } = setup();
  const pre = await handler(new Request("http://x", { method: "OPTIONS" }));
  assertEquals(pre.status, 204);
  assertEquals(pre.headers.get("Access-Control-Allow-Origin"), "*");
  const get = await handler(new Request("http://x", { method: "GET" }));
  assertEquals(get.status, 400);
});

Deno.test("ai-chat: 401 without valid session", async () => {
  const { handler } = setup();
  const r = await handler(post(body(), {}));
  assertEquals(r.status, 401);
  assertEquals((await r.json()).error.code, "unauthorized");
});

Deno.test("ai-chat: 400 invalid_request with field path; oversized body", async () => {
  const { handler, calls } = setup();
  const r = await handler(post(body({ request_id: "bad id" })));
  assertEquals(r.status, 400);
  const j = await r.json();
  assertEquals(j.error.code, "invalid_request");
  assert(j.error.message.includes("request_id"));
  const big = await handler(post(body({ system: "x".repeat(300 * 1024) })));
  assertEquals(big.status, 400);
  const notJson = await handler(post("{nope"));
  assertEquals(notJson.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("ai-chat: success returns the normalised contract and records usage + cache", async () => {
  const { handler, deps, calls } = setup();
  const r = await handler(post(body()));
  assertEquals(r.status, 200);
  const j = await r.json();
  assertEquals(j.request_id, "req_abcdef123");
  assertEquals(j.provider, "anthropic");
  assertEquals(j.model, "claude-sonnet-5-5");
  assertEquals(j.stop_reason, "tool_use");
  assertEquals(j.content, [
    { type: "opaque", provider: "anthropic", data: { type: "thinking", thinking: "t", signature: "s" } },
    { type: "text", text: "Logged!" },
    { type: "tool_call", id: "toolu_1", name: "log_water", arguments: { amount_ml: 500 } },
  ]);
  // 1000 in * $2/M + 100 out * $10/M = 0.003
  assertEquals(j.usage, { input_tokens: 1000, output_tokens: 100, cost_usd: 0.003 });
  assertEquals(j.meta.cached, false);
  assertEquals(j.meta.fallback_used, false);
  assertEquals(j.meta.attempts, 1);
  assertEquals(j.meta.budget, { month_spend_usd: 0.003, monthly_budget_usd: 10, percent: 0.03, alerts: [] });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].body.max_tokens, 4096);
  const usage = (deps.usage as InMemoryUsageStore).rows.get("req_abcdef123");
  assertEquals(usage?.status, "ok");
  assertEquals(usage?.credential_alias, "primary");
  assert((deps.cache as InMemoryResponseCache).data.has("req_abcdef123"));
});

Deno.test("ai-chat: same request_id is served from cache (no provider call)", async () => {
  const { handler, calls } = setup();
  await handler(post(body()));
  const again = await handler(post(body()));
  assertEquals(again.status, 200);
  const j = await again.json();
  assertEquals(j.meta.cached, true);
  assertEquals(j.content[1], { type: "text", text: "Logged!" });
  assertEquals(calls.length, 1);
});

Deno.test("ai-chat: request_id owned by another user -> 409", async () => {
  const { handler, deps } = setup();
  await deps.cache.put("req_abcdef123", "someone-else", { request_id: "req_abcdef123" });
  const r = await handler(post(body()));
  assertEquals(r.status, 409);
  assertEquals((await r.json()).error.code, "conflict");
});

Deno.test("ai-chat: rate limit -> 429 with retry_after_s", async () => {
  const { handler } = setup({ env: { AI_RATE_LIMIT_PER_MIN: "1" } });
  assertEquals((await handler(post(body({ request_id: "req_first_1" })))).status, 200);
  const r = await handler(post(body({ request_id: "req_second_2" })));
  assertEquals(r.status, 429);
  const j = await r.json();
  assertEquals(j.error.code, "rate_limited");
  assertEquals(j.error.retry_after_s, 60);
  assertEquals(r.headers.get("Retry-After"), "60");
});

Deno.test("ai-chat: budget exceeded -> 402 and refused usage row", async () => {
  const { handler, deps, calls } = setup({ env: { AI_MONTHLY_BUDGET_USD: "1" } });
  await deps.usage.record({
    user_id: "user-1",
    request_id: "old",
    provider: "anthropic",
    model: "claude-sonnet-5-5",
    credential_alias: "primary",
    input_tokens: 0,
    output_tokens: 0,
    cost_usd: 1,
    status: "ok",
    latency_ms: 1,
  });
  const r = await handler(post(body()));
  assertEquals(r.status, 402);
  assertEquals((await r.json()).error.code, "budget_exceeded");
  assertEquals(calls.length, 0);
  assertEquals((deps.usage as InMemoryUsageStore).rows.get("req_abcdef123")?.status, "refused");
});

Deno.test("ai-chat: budget alerts reported in meta", async () => {
  const { handler, deps } = setup();
  await deps.usage.record({
    user_id: "user-1",
    request_id: "old",
    provider: "anthropic",
    model: "m",
    credential_alias: "primary",
    input_tokens: 0,
    output_tokens: 0,
    cost_usd: 4.999,
    status: "ok",
    latency_ms: 1,
  });
  const j = await (await handler(post(body()))).json();
  assertEquals(j.meta.budget.alerts, [50]);
  assertEquals(j.meta.budget.month_spend_usd, 5.002);
});

Deno.test("ai-chat: no credentials -> 503 no_provider_configured", async () => {
  const { handler } = setup({ env: { ANTHROPIC_API_KEY: "", OPENAI_API_KEY: "" } });
  const r = await handler(post(body()));
  assertEquals(r.status, 503);
  assertEquals((await r.json()).error.code, "no_provider_configured");
});

Deno.test("ai-chat: primary_provider and model preferences", async () => {
  const { handler, calls } = setup();
  const r = await handler(post(body({ preferences: { primary_provider: "openai", model: "gpt-5.4-mini" } })));
  const j = await r.json();
  assertEquals(j.provider, "openai");
  assertEquals(j.model, "gpt-5.4-mini");
  assert(calls[0].url.includes("api.openai.com"));
  assertEquals(calls[0].body.model, "gpt-5.4-mini");
});

Deno.test("ai-chat: model preference only applies to its own provider; unknown model ignored", () => {
  const env = (n: string) => ({ ANTHROPIC_API_KEY: "a", OPENAI_API_KEY: "b" } as Record<string, string>)[n];
  const creds = loadCredentials(env);
  const table = loadPriceTable(env);
  assertEquals(buildPlan(env, creds, "openai", [], "claude-opus-5-5", table), [
    { provider: "openai", model: "gpt-5.4-mini" },
    { provider: "anthropic", model: "claude-opus-5-5" },
  ]);
  assertEquals(buildPlan(env, creds, null, ["gemini"], "not-a-model", table), [
    { provider: "anthropic", model: "claude-sonnet-5-5" },
    { provider: "openai", model: "gpt-5.4-mini" },
  ]);
});

Deno.test("ai-chat: transient failures fall back to the next provider", async () => {
  const fail = () =>
    new Response(JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "Overloaded" } }), {
      status: 529,
    });
  const { handler, calls } = setup({ anthropic: [fail] });
  const j = await (await handler(post(body()))).json();
  assertEquals(j.provider, "openai");
  assertEquals(j.meta.fallback_used, true);
  assertEquals(j.meta.attempts, 4);
  assertEquals(calls.filter((c) => c.url.includes("anthropic")).length, 3);
  // 2000 * 0.75/M + 200 * 4.5/M = 0.0024
  assertEquals(j.usage.cost_usd, 0.0024);
});

Deno.test("ai-chat: max_retries 0 means a single attempt per credential", async () => {
  const fail = () => new Response("{}", { status: 500 });
  const { handler, calls } = setup({ anthropic: [fail] });
  await handler(post(body({ preferences: { max_retries: 0 } })));
  assertEquals(calls.filter((c) => c.url.includes("anthropic")).length, 1);
});

Deno.test("ai-chat: all providers failing -> 502 upstream_error, error usage row, no secrets", async () => {
  const fail = () => new Response(JSON.stringify({ error: { message: `boom ${OPENAI_KEY}` } }), { status: 500 });
  const { handler, deps, logs } = setup({ anthropic: [fail], openai: [fail] });
  const r = await handler(post(body()));
  assertEquals(r.status, 502);
  const text = await r.text();
  assertEquals(JSON.parse(text).error.code, "upstream_error");
  assertFalse(text.includes("TESTKEY"));
  assertFalse(JSON.stringify(logs).includes("TESTKEY"));
  assertEquals((deps.usage as InMemoryUsageStore).rows.get("req_abcdef123")?.status, "error");
});

Deno.test("ai-chat: provider 400 -> 400 invalid_request without rotation", async () => {
  const bad = () =>
    new Response(
      JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "messages.0: bad" } }),
      { status: 400 },
    );
  const { handler, calls } = setup({ anthropic: [bad] });
  const r = await handler(post(body()));
  assertEquals(r.status, 400);
  assertEquals((await r.json()).error.code, "invalid_request");
  assertEquals(calls.length, 1);
});

Deno.test("ai-chat: invalid key rotates to the secondary credential", async () => {
  const keys: string[] = [];
  const { deps } = setup({ env: { ANTHROPIC_API_KEY_SECONDARY: "sk-ant-api03-SECONDARYSECONDARY" } });
  deps.fetchFn = ((_u: string | URL | Request, init?: RequestInit) => {
    const key = (init?.headers as Record<string, string>)["x-api-key"];
    keys.push(key);
    return Promise.resolve(
      key === ANTHROPIC_KEY
        ? new Response(
          JSON.stringify({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }),
          { status: 401 },
        )
        : anthropicOk(),
    );
  }) as typeof fetch;
  const r = await createChatHandler(deps)(post(body()));
  assertEquals(r.status, 200);
  assertEquals(keys, [ANTHROPIC_KEY, "sk-ant-api03-SECONDARYSECONDARY"]);
  assertEquals((await deps.health.get("anthropic", "primary"))?.status, "invalid");
});
