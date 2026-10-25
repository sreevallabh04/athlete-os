import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { clamp, LIMITS, readBodyLimited, validateChatRequest } from "./validate.ts";
import { conversation, WEATHER_TOOL } from "./testing.ts";

const valid = () => ({
  request_id: "req_12345678",
  conversation_id: null,
  system: "coach",
  messages: conversation("anthropic"),
  tools: [WEATHER_TOOL],
  preferences: {
    primary_provider: "openai",
    model: null,
    fallback_providers: ["gemini"],
    max_tokens: 99999,
    timeout_ms: 60000,
    max_retries: 2,
    monthly_budget_usd: 5,
  },
});

function expectInvalid(body: unknown, path: string) {
  const r = validateChatRequest(body);
  assertFalse(r.ok, `expected invalid at ${path}`);
  if (!r.ok) assertEquals(r.path, path);
}

Deno.test("validate: accepts the contract example", () => {
  const r = validateChatRequest(valid());
  assert(r.ok);
  if (r.ok) {
    assertEquals(r.value.preferences.primary_provider, "openai");
    assertEquals(r.value.preferences.fallback_providers, ["gemini"]);
    assertEquals(r.value.messages.length, 3);
    assertEquals(r.value.tools[0].input_schema.type, "object");
  }
});

Deno.test("validate: request_id format", () => {
  expectInvalid({ ...valid(), request_id: "short" }, "request_id");
  expectInvalid({ ...valid(), request_id: "has space 123" }, "request_id");
  expectInvalid({ ...valid(), request_id: "x".repeat(81) }, "request_id");
});

Deno.test("validate: block role rules and field paths", () => {
  const b = valid();
  b.messages[0].content = [{ type: "tool_call", id: "1", name: "x", arguments: {} }];
  expectInvalid(b, "messages[0].content[0].type");
  const c = valid();
  c.messages[1].content = [{ type: "tool_result", tool_call_id: "1", name: "x", content: "" }];
  expectInvalid(c, "messages[1].content[0].type");
  const d = valid();
  d.messages[1].content = [{ type: "opaque", provider: "mistral" as "openai", data: {} }];
  expectInvalid(d, "messages[1].content[0].provider");
  const e = valid();
  e.messages[0].content = [{ type: "text", text: "x".repeat(LIMITS.textChars + 1) }];
  expectInvalid(e, "messages[0].content[0].text");
});

Deno.test("validate: limits on messages, system, tools", () => {
  expectInvalid({ ...valid(), system: "x".repeat(12_001) }, "system");
  expectInvalid({
    ...valid(),
    messages: Array.from({ length: 61 }, () => ({ role: "user", content: [{ type: "text", text: "a" }] })),
  }, "messages");
  expectInvalid({
    ...valid(),
    messages: [{ role: "user", content: Array.from({ length: 41 }, () => ({ type: "text", text: "a" })) }],
  }, "messages[0].content");
  expectInvalid(
    { ...valid(), tools: Array.from({ length: 41 }, (_, i) => ({ ...WEATHER_TOOL, name: `t${i}` })) },
    "tools",
  );
  expectInvalid({ ...valid(), tools: [{ ...WEATHER_TOOL, name: "bad name!" }] }, "tools[0].name");
  expectInvalid({ ...valid(), tools: [WEATHER_TOOL, WEATHER_TOOL] }, "tools[1].name");
  expectInvalid({
    ...valid(),
    tools: [{ ...WEATHER_TOOL, input_schema: { type: "object", description: "x".repeat(5000) } }],
  }, "tools[0].input_schema");
  expectInvalid(
    { ...valid(), messages: [{ role: "assistant", content: [{ type: "text", text: "a" }] }] },
    "messages[0].role",
  );
});

Deno.test("validate: preferences types", () => {
  expectInvalid({ ...valid(), preferences: { primary_provider: "mistral" } }, "preferences.primary_provider");
  expectInvalid({ ...valid(), preferences: { max_tokens: "lots" } }, "preferences.max_tokens");
  expectInvalid({ ...valid(), preferences: { monthly_budget_usd: -1 } }, "preferences.monthly_budget_usd");
  assert(validateChatRequest({ ...valid(), preferences: undefined }).ok);
});

Deno.test("clamp", () => {
  assertEquals(clamp(99999, LIMITS.maxTokens, 4096), 16000);
  assertEquals(clamp(1, LIMITS.maxTokens, 4096), 256);
  assertEquals(clamp(null, LIMITS.timeoutMs, 60000), 60000);
  assertEquals(clamp(7, LIMITS.maxRetries, 2), 3);
});

Deno.test("readBodyLimited enforces the byte limit", async () => {
  const small = new Request("http://x", { method: "POST", body: "hello" });
  assertEquals(await readBodyLimited(small, 10), "hello");
  const big = new Request("http://x", { method: "POST", body: "x".repeat(11) });
  assertEquals(await readBodyLimited(big, 10), null);
});
