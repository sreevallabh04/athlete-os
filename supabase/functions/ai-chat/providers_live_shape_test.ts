// ai-chat with the production provider pair (Gemini primary, Groq fallback)
// and image routing. Network is faked.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { type ChatDeps, createChatHandler } from "./handler.ts";
import { InMemoryRateLimitStore } from "../_shared/ratelimit.ts";
import { type Clock, InMemoryBreakerStore, InMemoryHealthStore } from "../_shared/resilience.ts";
import { InMemoryResponseCache, InMemoryUsageStore, InMemoryUserSettingsStore } from "../_shared/stores.ts";
import { WEATHER_TOOL } from "../_shared/testing.ts";

const ENV: Record<string, string> = {
  GEMINI_API_KEY: "AIzaPRIMARYTESTKEYxxxxxxxxxxxx",
  GEMINI_API_KEY_SECONDARY: "AIzaSECONDARYTESTKEYxxxxxxxxx",
  GROQ_API_KEY: "gsk_GROQTESTKEYxxxxxxxxxxxxxxxx",
  AI_PROVIDER_ORDER: "gemini,groq",
};

type Route = (body: Record<string, unknown>, headers: Headers) => Response;

function setup(routes: { gemini?: Route; groq?: Route }) {
  const calls: { url: string; body: Record<string, unknown>; headers: Headers }[] = [];
  const fetchFn = ((url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    const body = JSON.parse(String(init?.body));
    const headers = new Headers(init?.headers);
    calls.push({ url: u, body, headers });
    const route = u.includes("groq.com") ? routes.groq : routes.gemini;
    return Promise.resolve(route ? route(body, headers) : new Response("{}", { status: 500 }));
  }) as typeof fetch;
  const clock: Clock & { t: number } = {
    t: Date.UTC(2026, 9, 25, 12),
    now: () => clock.t,
    sleep: (ms) => {
      clock.t += ms;
      return Promise.resolve();
    },
    random: () => 0.5,
  };
  const deps: ChatDeps = {
    env: (n) => ENV[n],
    authenticate: () => Promise.resolve("user-1"),
    cache: new InMemoryResponseCache(() => clock.t),
    rateLimits: new InMemoryRateLimitStore(),
    usage: new InMemoryUsageStore(() => clock.t),
    userSettings: new InMemoryUserSettingsStore(),
    health: new InMemoryHealthStore(),
    breakerStore: new InMemoryBreakerStore(),
    fetchFn,
    clock,
    log: () => {},
  };
  return { handler: createChatHandler(deps), calls, deps };
}

const post = (b: unknown) =>
  new Request("http://localhost/functions/v1/ai-chat", {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: "Bearer jwt" },
    body: JSON.stringify(b),
  });

const req = (content: unknown[], id = "req_live_shape_1") => ({
  request_id: id,
  system: "coach",
  messages: [{ role: "user", content }],
  tools: [WEATHER_TOOL],
});

const groqToolCall: Route = () =>
  new Response(JSON.stringify({
    choices: [{
      finish_reason: "tool_calls",
      message: {
        role: "assistant",
        content: null,
        tool_calls: [{
          id: "call_g",
          type: "function",
          function: { name: "log_water", arguments: '{"amount_ml":250}' },
        }],
      },
    }],
    usage: { prompt_tokens: 1000, completion_tokens: 100 },
  }));

Deno.test("ai-chat: invalid Gemini primary key -> Gemini secondary (same provider, no Groq)", async () => {
  const { handler, calls, deps } = setup({
    gemini: (_b, h) =>
      h.get("x-goog-api-key") === ENV.GEMINI_API_KEY
        ? new Response(
          JSON.stringify({ error: { code: 400, status: "INVALID_ARGUMENT", message: "API key not valid." } }),
          { status: 400 },
        )
        : new Response(JSON.stringify({
          candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
          usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 2 },
        })),
  });
  const r = await handler(post(req([{ type: "text", text: "hi" }])));
  const j = await r.json();
  assertEquals(r.status, 200);
  assertEquals(j.provider, "gemini");
  assertEquals(j.meta.fallback_used, false);
  assertEquals(calls.length, 2);
  assertEquals((await deps.health.get("gemini", "primary"))?.status, "invalid");
});

Deno.test("ai-chat: Gemini unavailable -> Groq fallback with normalised tool_call and groq pricing", async () => {
  const { handler, calls } = setup({
    gemini: () =>
      new Response(JSON.stringify({ error: { code: 503, status: "UNAVAILABLE", message: "overloaded" } }), {
        status: 503,
      }),
    groq: groqToolCall,
  });
  const j = await (await handler(post(req([{ type: "text", text: "log 250ml" }])))).json();
  assertEquals(j.provider, "groq");
  assertEquals(j.model, "openai/gpt-oss-120b");
  assertEquals(j.meta.fallback_used, true);
  assertEquals(j.content, [{ type: "tool_call", id: "call_g", name: "log_water", arguments: { amount_ml: 250 } }]);
  assertEquals(j.stop_reason, "tool_use");
  // 1000 * 0.15/M + 100 * 0.60/M
  assertEquals(j.usage.cost_usd, 0.00021);
  // retries stay on the same Gemini key (transient), never rotate
  assertEquals(calls.filter((c) => c.url.includes("googleapis")).length, 3);
  assert(calls.every((c) => !c.url.includes("googleapis") || c.headers.get("x-goog-api-key") === ENV.GEMINI_API_KEY));
});

Deno.test("ai-chat: image requests are only routed to image-capable providers", async () => {
  const { handler, calls } = setup({
    gemini: () =>
      new Response(JSON.stringify({ error: { code: 503, status: "UNAVAILABLE", message: "overloaded" } }), {
        status: 503,
      }),
    groq: groqToolCall,
  });
  const r = await handler(post(req([
    { type: "text", text: "estimate this meal" },
    { type: "image", media_type: "image/jpeg", data: "/9j/AAAA" },
  ], "req_image_123")));
  assertEquals(r.status, 502);
  assert(calls.every((c) => !c.url.includes("groq.com")));
  const inline = (calls[0].body.contents as { parts: Record<string, unknown>[] }[])[0].parts[1];
  assertEquals(inline, { inlineData: { mimeType: "image/jpeg", data: "/9j/AAAA" } });
});

Deno.test("ai-chat: image body may exceed the text body limit, text-only may not", async () => {
  const { handler } = setup({
    gemini: () =>
      new Response(JSON.stringify({
        candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
        usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 2 },
      })),
  });
  const bigImage = "A".repeat(400 * 1024);
  const ok = await handler(post(req([{ type: "image", media_type: "image/jpeg", data: bigImage }], "req_bigimg_1")));
  assertEquals(ok.status, 200);
  const manyTexts = Array.from({ length: 20 }, () => ({ type: "text", text: "x".repeat(15_000) }));
  const tooBig = await handler(post(req(manyTexts, "req_bigtext_1")));
  assertEquals(tooBig.status, 400);
});
