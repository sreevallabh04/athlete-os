import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { GROQ_URL, groqAdapter, mapGroqMessages } from "./groq.ts";
import { IMAGE_PLACEHOLDER } from "./util.ts";
import { classifyError, isLongRateLimit } from "../resilience.ts";
import { bodyOf, conversation, headersOf, input } from "../testing.ts";

Deno.test("groq request: url, bearer auth, chat-completions body", () => {
  const { url, init } = groqAdapter.buildRequest(
    { ...input(conversation("gemini")), model: "openai/gpt-oss-120b" },
    "gsk_test_abcdefghijklmnop",
  );
  assertEquals(url, GROQ_URL);
  assertEquals(url, "https://api.groq.com/openai/v1/chat/completions");
  assertEquals(headersOf(init)["authorization"], "Bearer gsk_test_abcdefghijklmnop");
  const body = bodyOf(init);
  assertEquals(body.model, "openai/gpt-oss-120b");
  assertEquals(body.max_completion_tokens, 1024);
  assertEquals(body.tool_choice, "auto");
  const tools = body.tools as Record<string, unknown>[];
  assertEquals(tools[0].type, "function");
  const fn = tools[0].function as Record<string, unknown>;
  assertEquals(fn.name, "log_water");
  assertEquals(fn.description, "Log a water intake entry");
  assert(fn.parameters);
  for (const k of ["temperature", "top_p", "max_tokens", "reasoning_format"]) assertFalse(k in body);
});

Deno.test("groq request: no tools -> no tools/tool_choice", () => {
  const body = bodyOf(groqAdapter.buildRequest(input(conversation("gemini"), []), "k").init);
  assertFalse("tools" in body);
  assertFalse("tool_choice" in body);
});

Deno.test("groq request: messages mapping (system, assistant tool_calls, role:tool results)", () => {
  const body = bodyOf(groqAdapter.buildRequest(input(conversation("anthropic")), "k").init);
  assertEquals(body.messages, [
    { role: "system", content: "You are a coach." },
    { role: "user", content: "Log 500 ml of water" },
    {
      role: "assistant",
      content: "Logging it.",
      tool_calls: [{ id: "call_1", type: "function", function: { name: "log_water", arguments: '{"amount_ml":500}' } }],
    },
    { role: "tool", tool_call_id: "call_1", name: "log_water", content: '{"ok":true}' },
  ]);
});

Deno.test("groq request: tool results precede user text; errors wrapped; images become a placeholder", () => {
  const msgs = mapGroqMessages("", [
    { role: "user", content: [{ type: "text", text: "hi" }] },
    { role: "assistant", content: [{ type: "tool_call", id: "a", name: "t", arguments: {} }] },
    {
      role: "user",
      content: [
        { type: "text", text: "also this" },
        { type: "tool_result", tool_call_id: "a", name: "t", content: '{"msg":"boom"}', is_error: true },
        { type: "image", media_type: "image/jpeg", data: "AAAA" },
      ],
    },
  ]);
  assertEquals(msgs, [
    { role: "user", content: "hi" },
    {
      role: "assistant",
      content: null,
      tool_calls: [{ id: "a", type: "function", function: { name: "t", arguments: "{}" } }],
    },
    { role: "tool", tool_call_id: "a", name: "t", content: '{"error":{"msg":"boom"}}' },
    { role: "user", content: `also this\n\n${IMAGE_PLACEHOLDER}` },
  ]);
});

Deno.test("groq response: tool_calls parsed, reasoning dropped, usage mapped", () => {
  const r = groqAdapter.parseResponse({
    id: "chatcmpl-1",
    object: "chat.completion",
    choices: [{
      index: 0,
      finish_reason: "tool_calls",
      message: {
        role: "assistant",
        content: null,
        reasoning: "I should call the tool",
        tool_calls: [{
          id: "call_x",
          type: "function",
          function: { name: "get_steps_summary", arguments: '{"date":"2026-10-25"}' },
        }],
      },
    }],
    usage: { prompt_tokens: 210, completion_tokens: 31, total_tokens: 241 },
  });
  assertEquals(r.content, [
    { type: "tool_call", id: "call_x", name: "get_steps_summary", arguments: { date: "2026-10-25" } },
  ]);
  assertEquals(r.stop_reason, "tool_use");
  assertEquals(r.usage, { input_tokens: 210, output_tokens: 31 });
});

Deno.test("groq response: text, stop reasons, bad JSON arguments", () => {
  const text = groqAdapter.parseResponse({
    choices: [{ finish_reason: "stop", message: { role: "assistant", content: "Hello" } }],
  });
  assertEquals(text.content, [{ type: "text", text: "Hello" }]);
  assertEquals(text.stop_reason, "end_turn");
  assertEquals(
    groqAdapter.parseResponse({ choices: [{ finish_reason: "length", message: { content: "x" } }] }).stop_reason,
    "max_tokens",
  );
  assertEquals(
    groqAdapter.parseResponse({ choices: [{ finish_reason: "content_filter", message: {} }] }).stop_reason,
    "refusal",
  );
  const bad = groqAdapter.parseResponse({
    choices: [{
      finish_reason: "tool_calls",
      message: { tool_calls: [{ id: "c", type: "function", function: { name: "t", arguments: "{oops" } }] },
    }],
  });
  assertEquals(bad.content, [{
    type: "tool_call",
    id: "c",
    name: "t",
    arguments: {},
    provider_meta: { raw_arguments: "{oops" },
  }]);
  assertEquals(groqAdapter.parseResponse({}).content, []);
});

const err = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  groqAdapter.parseError(status, new Headers(headers), JSON.stringify(body));

Deno.test("groq errors: classification", () => {
  assertEquals(
    classifyError(
      err(401, { error: { message: "Invalid API Key", type: "invalid_request_error", code: "invalid_api_key" } }),
    ),
    "invalid_credential",
  );
  assertEquals(classifyError(err(500, { error: { message: "internal" } })), "transient");
  assertEquals(classifyError(err(503, { error: { message: "over capacity" } })), "transient");
  assertEquals(classifyError(err(498, { error: { message: "flex capacity" } })), "transient");
  assertEquals(
    classifyError(err(400, { error: { message: "Failed to call a function", code: "tool_use_failed" } })),
    "transient",
  );
  assertEquals(classifyError(err(400, { error: { message: "bad", code: "invalid_value" } })), "bad_request");
  assertEquals(
    classifyError(
      err(413, {
        error: {
          message: "Request too large for model `openai/gpt-oss-120b` on tokens per minute (TPM): Limit 8000",
          type: "tokens",
          code: "rate_limit_exceeded",
        },
      }),
    ),
    "request_too_large",
  );
});

Deno.test("groq errors: 429 retry hints and daily exhaustion", () => {
  const short = err(429, { error: { message: "Rate limit reached (TPM)", code: "rate_limit_exceeded" } }, {
    "retry-after": "3",
  });
  assertEquals(classifyError(short), "rate_limited");
  assertEquals(short.retryAfterMs, 3000);
  assertFalse(isLongRateLimit(short));

  const tokens = err(429, { error: { message: "Rate limit" } }, {
    "x-ratelimit-remaining-tokens": "0",
    "x-ratelimit-reset-tokens": "7.66s",
  });
  assertEquals(tokens.retryAfterMs, 7660);
  assertEquals(classifyError(tokens), "rate_limited");

  const daily = err(429, { error: { message: "Rate limit reached on requests per day (RPD)" } }, {
    "retry-after": "2",
    "x-ratelimit-remaining-requests": "0",
    "x-ratelimit-reset-requests": "2h3m4s",
  });
  assertEquals(classifyError(daily), "quota_exhausted");
  assertEquals(daily.cooldownMs, 7_384_000);

  const long = err(429, { error: { message: "Rate limit" } }, { "retry-after": "120" });
  assertEquals(classifyError(long), "quota_exhausted");
  assertEquals(long.cooldownMs, 120_000);
});
