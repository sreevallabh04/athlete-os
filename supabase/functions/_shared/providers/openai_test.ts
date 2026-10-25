import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { OPENAI_URL, openaiAdapter } from "./openai.ts";
import { classifyError, isLongRateLimit } from "../resilience.ts";
import { bodyOf, conversation, headersOf, input } from "../testing.ts";

const reasoning = { type: "reasoning", id: "rs_1", summary: [], encrypted_content: "enc" };

Deno.test("openai request: url, auth header, body shape", () => {
  const { url, init } = openaiAdapter.buildRequest(input(conversation("openai")), "sk-test-abcdefghijklmnop");
  assertEquals(url, OPENAI_URL);
  assertEquals(headersOf(init)["authorization"], "Bearer sk-test-abcdefghijklmnop");
  const body = bodyOf(init);
  assertEquals(body.model, "m-1");
  assertEquals(body.instructions, "You are a coach.");
  assertEquals(body.max_output_tokens, 1024);
  assertEquals(body.store, false);
  assertEquals(body.include, ["reasoning.encrypted_content"]);
  assertEquals(body.tool_choice, "auto");
  const tools = body.tools as Record<string, unknown>[];
  assertEquals(tools[0].type, "function");
  assertEquals(tools[0].name, "log_water");
  assertEquals(tools[0].description, "Log a water intake entry");
  assert(tools[0].parameters);
  assertEquals(tools[0].strict, false);
  for (const k of ["temperature", "top_p"]) assertFalse(k in body);
});

Deno.test("openai request: no tools -> no tools/tool_choice", () => {
  const body = bodyOf(openaiAdapter.buildRequest(input(conversation("openai"), []), "k").init);
  assertFalse("tools" in body);
  assertFalse("tool_choice" in body);
});

Deno.test("openai request: input items mapping with opaque replay in position", () => {
  const msgs = conversation("openai");
  // replace the fixture's opaque data with a real reasoning item
  (msgs[1].content[0] as { data: unknown }).data = reasoning;
  const body = bodyOf(openaiAdapter.buildRequest(input(msgs), "k").init);
  assertEquals(body.input, [
    { role: "user", content: [{ type: "input_text", text: "Log 500 ml of water" }] },
    reasoning,
    { role: "assistant", content: [{ type: "output_text", text: "Logging it." }] },
    { type: "function_call", call_id: "call_1", name: "log_water", arguments: '{"amount_ml":500}' },
    { type: "function_call_output", call_id: "call_1", output: '{"ok":true}' },
  ]);
});

Deno.test("openai request: opaque of other providers dropped", () => {
  const body = bodyOf(openaiAdapter.buildRequest(input(conversation("anthropic")), "k").init);
  const items = body.input as Record<string, unknown>[];
  assertFalse(items.some((i) => i.type === "thinking"));
  assertEquals(items.length, 4);
});

Deno.test("openai response: message text, function_call args JSON, reasoning opaque, usage", () => {
  const r = openaiAdapter.parseResponse({
    status: "completed",
    output: [
      reasoning,
      {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "Hi ", annotations: [] }, { type: "output_text", text: "there" }],
      },
      { type: "function_call", id: "fc_1", call_id: "call_9", name: "log_water", arguments: '{"amount_ml":300}' },
    ],
    usage: { input_tokens: 50, output_tokens: 12 },
  });
  assertEquals(r.content, [
    { type: "opaque", provider: "openai", data: reasoning },
    { type: "text", text: "Hi there" },
    { type: "tool_call", id: "call_9", name: "log_water", arguments: { amount_ml: 300 } },
  ]);
  assertEquals(r.stop_reason, "tool_use");
  assertEquals(r.usage, { input_tokens: 50, output_tokens: 12 });
});

Deno.test("openai response: invalid arguments JSON -> {} plus raw_arguments", () => {
  const r = openaiAdapter.parseResponse({
    status: "completed",
    output: [{ type: "function_call", call_id: "c", name: "t", arguments: "{oops" }],
  });
  assertEquals(r.content, [{
    type: "tool_call",
    id: "c",
    name: "t",
    arguments: {},
    provider_meta: { raw_arguments: "{oops" },
  }]);
});

Deno.test("openai response: stop reasons", () => {
  assertEquals(openaiAdapter.parseResponse({ status: "completed", output: [] }).stop_reason, "end_turn");
  assertEquals(
    openaiAdapter.parseResponse({
      status: "incomplete",
      incomplete_details: { reason: "max_output_tokens" },
      output: [],
    })
      .stop_reason,
    "max_tokens",
  );
  assertEquals(
    openaiAdapter.parseResponse({
      status: "completed",
      output: [{ type: "message", content: [{ type: "refusal", refusal: "I can't help" }] }],
    }).stop_reason,
    "refusal",
  );
});

const err = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  openaiAdapter.parseError(status, new Headers(headers), JSON.stringify(body));

Deno.test("openai errors: classification", () => {
  assertEquals(
    classifyError(err(401, { error: { message: "Incorrect API key", code: "invalid_api_key" } })),
    "invalid_credential",
  );
  assertEquals(
    classifyError(
      err(429, {
        error: { message: "You exceeded your current quota", type: "insufficient_quota", code: "insufficient_quota" },
      }),
    ),
    "quota_exhausted",
  );
  assertEquals(classifyError(err(500, { error: { message: "server" } })), "transient");
  assertEquals(classifyError(err(503, { error: { message: "overloaded" } })), "transient");
  assertEquals(classifyError(err(400, { error: { message: "bad param", code: "invalid_value" } })), "bad_request");
});

Deno.test("openai errors: rate limit retry hints", () => {
  const a = err(429, { error: { message: "Rate limit", code: "rate_limit_exceeded" } }, { "retry-after-ms": "1500" });
  assertEquals(classifyError(a), "rate_limited");
  assertEquals(a.retryAfterMs, 1500);
  const b = err(429, { error: { message: "Rate limit" } }, { "retry-after": "30" });
  assertEquals(b.retryAfterMs, 30_000);
  assert(isLongRateLimit(b));
  const c = err(429, { error: { message: "Rate limit" } }, { "x-ratelimit-reset-requests": "6m0s" });
  assertEquals(c.retryAfterMs, 360_000);
  const d = err(429, { error: { message: "Rate limit" } }, { "x-ratelimit-reset-requests": "20ms" });
  assertEquals(d.retryAfterMs, 20);
});
