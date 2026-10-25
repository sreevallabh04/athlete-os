import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { ANTHROPIC_URL, anthropicAdapter } from "./anthropic.ts";
import { classifyError, isLongRateLimit } from "../resilience.ts";
import { bodyOf, conversation, headersOf, input } from "../testing.ts";

Deno.test("anthropic request: url, headers, system, tools, tool_choice auto", () => {
  const { url, init } = anthropicAdapter.buildRequest(input(conversation("anthropic")), "sk-ant-test-key-123456");
  assertEquals(url, ANTHROPIC_URL);
  assertEquals(init.method, "POST");
  const h = headersOf(init);
  assertEquals(h["x-api-key"], "sk-ant-test-key-123456");
  assertEquals(h["anthropic-version"], "2023-06-01");
  assertEquals(h["content-type"], "application/json");
  const body = bodyOf(init);
  assertEquals(body.model, "m-1");
  assertEquals(body.max_tokens, 1024);
  assertEquals(body.system, "You are a coach.");
  assertEquals(body.tool_choice, { type: "auto" });
  const tools = body.tools as Record<string, unknown>[];
  assertEquals(tools[0].name, "log_water");
  assertEquals(tools[0].description, "Log a water intake entry");
  assert(tools[0].input_schema);
  for (const k of ["temperature", "top_p", "top_k", "thinking", "output_config"]) assertFalse(k in body, k);
});

Deno.test("anthropic request: no tools -> no tools/tool_choice; effort -> output_config", () => {
  const i = { ...input(conversation("anthropic"), []), effort: "low" as const };
  const body = bodyOf(anthropicAdapter.buildRequest(i, "k").init);
  assertFalse("tools" in body);
  assertFalse("tool_choice" in body);
  assertEquals(body.output_config, { effort: "low" });
});

Deno.test("anthropic request: message mapping and opaque replay in position", () => {
  const body = bodyOf(anthropicAdapter.buildRequest(input(conversation("anthropic")), "k").init);
  const msgs = body.messages as { role: string; content: Record<string, unknown>[] }[];
  assertEquals(msgs.length, 3);
  assertEquals(msgs[0], { role: "user", content: [{ type: "text", text: "Log 500 ml of water" }] });
  assertEquals(msgs[1].role, "assistant");
  assertEquals(msgs[1].content, [
    { type: "thinking", thinking: "hmm", signature: "sig-1" },
    { type: "text", text: "Logging it." },
    { type: "tool_use", id: "call_1", name: "log_water", input: { amount_ml: 500 } },
  ]);
  assertEquals(msgs[2].content, [
    { type: "tool_result", tool_use_id: "call_1", content: '{"ok":true}', is_error: false },
  ]);
});

Deno.test("anthropic request: opaque blocks of other providers are dropped", () => {
  const body = bodyOf(anthropicAdapter.buildRequest(input(conversation("openai")), "k").init);
  const msgs = body.messages as { content: Record<string, unknown>[] }[];
  assertEquals(msgs[1].content.map((b) => b.type), ["text", "tool_use"]);
});

Deno.test("anthropic request: empty assistant message dropped and same-role turns merged", () => {
  const body = bodyOf(
    anthropicAdapter.buildRequest(
      input([
        { role: "user", content: [{ type: "text", text: "a" }] },
        { role: "assistant", content: [{ type: "opaque", provider: "gemini", data: { x: 1 } }] },
        { role: "user", content: [{ type: "text", text: "b" }] },
      ]),
      "k",
    ).init,
  );
  assertEquals(body.messages, [{ role: "user", content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] }]);
});

Deno.test("anthropic response: text, tool_use, thinking opaque, usage incl. cache tokens", () => {
  const thinking = { type: "thinking", thinking: "plan", signature: "abc" };
  const redacted = { type: "redacted_thinking", data: "xyz" };
  const r = anthropicAdapter.parseResponse({
    content: [
      thinking,
      redacted,
      { type: "text", text: "Sure." },
      { type: "tool_use", id: "toolu_1", name: "log_water", input: { amount_ml: 250 } },
    ],
    stop_reason: "tool_use",
    usage: { input_tokens: 100, cache_creation_input_tokens: 20, cache_read_input_tokens: 5, output_tokens: 40 },
  });
  assertEquals(r.content, [
    { type: "opaque", provider: "anthropic", data: thinking },
    { type: "opaque", provider: "anthropic", data: redacted },
    { type: "text", text: "Sure." },
    { type: "tool_call", id: "toolu_1", name: "log_water", arguments: { amount_ml: 250 } },
  ]);
  assertEquals(r.stop_reason, "tool_use");
  assertEquals(r.usage, { input_tokens: 125, output_tokens: 40 });
});

Deno.test("anthropic response: stop reason mapping", () => {
  const sr = (s: string) => anthropicAdapter.parseResponse({ content: [], stop_reason: s, usage: {} }).stop_reason;
  assertEquals(sr("end_turn"), "end_turn");
  assertEquals(sr("stop_sequence"), "end_turn");
  assertEquals(sr("tool_use"), "tool_use");
  assertEquals(sr("max_tokens"), "max_tokens");
  assertEquals(sr("refusal"), "refusal");
  assertEquals(sr("pause_turn"), "other");
});

const err = (status: number, type: string, message: string, headers: Record<string, string> = {}) =>
  anthropicAdapter.parseError(
    status,
    new Headers(headers),
    JSON.stringify({ type: "error", error: { type, message } }),
  );

Deno.test("anthropic errors: classification", () => {
  assertEquals(classifyError(err(401, "authentication_error", "invalid x-api-key")), "invalid_credential");
  assertEquals(classifyError(err(403, "permission_error", "nope")), "invalid_credential");
  assertEquals(classifyError(err(529, "overloaded_error", "Overloaded")), "transient");
  assertEquals(classifyError(err(500, "api_error", "boom")), "transient");
  assertEquals(classifyError(err(400, "invalid_request_error", "Your credit balance is too low")), "quota_exhausted");
  assertEquals(
    classifyError(err(400, "invalid_request_error", "You have reached your spend limit")),
    "quota_exhausted",
  );
  assertEquals(classifyError(err(400, "invalid_request_error", "messages: field required")), "bad_request");
});

Deno.test("anthropic errors: 429 with short and long retry-after", () => {
  const short = err(429, "rate_limit_error", "slow down", { "retry-after": "7" });
  assertEquals(classifyError(short), "rate_limited");
  assertEquals(short.retryAfterMs, 7000);
  assertFalse(isLongRateLimit(short));
  const long = err(429, "rate_limit_error", "slow down", { "retry-after": "45" });
  assert(isLongRateLimit(long));
});

Deno.test("anthropic errors: non-JSON body falls back to text", () => {
  const e = anthropicAdapter.parseError(502, new Headers(), "<html>Bad gateway</html>");
  assertEquals(classifyError(e), "transient");
  assert(e.message.includes("Bad gateway"));
});
