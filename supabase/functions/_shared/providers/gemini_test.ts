import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  GEMINI_DUMMY_THOUGHT_SIGNATURE,
  GEMINI_THINKING_HEADROOM,
  geminiAdapter,
  sanitizeGeminiSchema,
} from "./gemini.ts";
import { classifyError } from "../resilience.ts";
import type { ToolCallBlock } from "./types.ts";
import { bodyOf, conversation, headersOf, input, WEATHER_TOOL } from "../testing.ts";

Deno.test("gemini request: url, header, system, tools, generationConfig", () => {
  const { url, init } = geminiAdapter.buildRequest(
    { ...input(conversation("gemini")), model: "gemini-3.8-flash" },
    "AIzaTestKey",
  );
  assertEquals(url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent");
  assertEquals(headersOf(init)["x-goog-api-key"], "AIzaTestKey");
  const body = bodyOf(init);
  assertEquals(body.systemInstruction, { parts: [{ text: "You are a coach." }] });
  // Thought tokens count toward the cap: headroom is added and reasoning kept light.
  assertEquals(body.generationConfig, {
    maxOutputTokens: 1024 + GEMINI_THINKING_HEADROOM,
    thinkingConfig: { thinkingLevel: "low" },
  });
  const decl = (body.tools as { functionDeclarations: Record<string, unknown>[] }[])[0].functionDeclarations[0];
  assertEquals(decl.name, "log_water");
  const params = decl.parameters as Record<string, unknown>;
  assertFalse("additionalProperties" in params);
  assertFalse("$schema" in params);
  for (const k of ["temperature", "toolConfig"]) assertFalse(k in body);
});

Deno.test("gemini schema sanitiser keeps supported keys only", () => {
  const s = sanitizeGeminiSchema(WEATHER_TOOL.input_schema) as {
    type: string;
    required: string[];
    properties: Record<string, unknown>;
  };
  assertEquals(s.type, "object");
  assertEquals(s.required, ["amount_ml"]);
  assertEquals(s.properties.amount_ml, { type: "integer", minimum: 1, maximum: 5000, description: "Amount in ml" });
  assertEquals(s.properties.logged_at, { type: "string", format: "date-time" });
  // unsupported format dropped, ["string","null"] -> nullable
  assertEquals(s.properties.note, { type: "string", nullable: true, maxLength: 200 });
  assertEquals(s.properties.tags, { type: "array", items: { type: "string", enum: ["a", "b"] }, maxItems: 3 });
});

Deno.test("gemini request: tool without properties omits parameters", () => {
  const body = bodyOf(
    geminiAdapter.buildRequest(
      input(conversation("gemini"), [{
        name: "noop",
        description: "x",
        input_schema: { type: "object", properties: {} },
      }]),
      "k",
    ).init,
  );
  const decl = (body.tools as { functionDeclarations: Record<string, unknown>[] }[])[0].functionDeclarations[0];
  assertFalse("parameters" in decl);
});

Deno.test("gemini request: contents mapping with thought signature and functionResponse", () => {
  const body = bodyOf(geminiAdapter.buildRequest(input(conversation("gemini")), "k").init);
  const contents = body.contents as { role: string; parts: Record<string, unknown>[] }[];
  assertEquals(contents.length, 3);
  assertEquals(contents[0], { role: "user", parts: [{ text: "Log 500 ml of water" }] });
  assertEquals(contents[1].role, "model");
  assertEquals(contents[1].parts, [
    { type: "thinking", thinking: "hmm", signature: "sig-1" }, // gemini opaque replayed verbatim
    { text: "Logging it." },
    { functionCall: { name: "log_water", args: { amount_ml: 500 } }, thoughtSignature: "gem-sig" },
  ]);
  assertEquals(contents[2], {
    role: "user",
    parts: [{ functionResponse: { name: "log_water", response: { result: { ok: true } } } }],
  });
});

Deno.test("gemini request: error tool_result and non-JSON content", () => {
  const msgs = conversation("gemini");
  msgs[2].content = [{
    type: "tool_result",
    tool_call_id: "call_1",
    name: "log_water",
    content: "denied",
    is_error: true,
  }];
  const body = bodyOf(geminiAdapter.buildRequest(input(msgs), "k").init);
  const contents = body.contents as { parts: Record<string, unknown>[] }[];
  assertEquals(contents[2].parts[0], { functionResponse: { name: "log_water", response: { error: "denied" } } });
});

Deno.test("gemini request: foreign tool calls get dummy signature on first call; other opaque dropped", () => {
  const msgs = conversation("anthropic");
  (msgs[1].content[2] as ToolCallBlock).provider_meta = undefined;
  const body = bodyOf(geminiAdapter.buildRequest(input(msgs), "k").init);
  const parts = (body.contents as { parts: Record<string, unknown>[] }[])[1].parts;
  assertEquals(parts.length, 2); // anthropic thinking dropped
  assertEquals(parts[1].thoughtSignature, GEMINI_DUMMY_THOUGHT_SIGNATURE);
});

Deno.test("gemini response: text, thought opaque, functionCall with signature, usage", () => {
  const thought = { text: "thinking...", thought: true };
  const r = geminiAdapter.parseResponse({
    candidates: [{
      content: {
        role: "model",
        parts: [
          thought,
          { text: "Logging." },
          { functionCall: { name: "log_water", args: { amount_ml: 200 } }, thoughtSignature: "SIG==" },
          { functionCall: { id: "fc-7", name: "log_water", args: { amount_ml: 100 } } },
        ],
      },
      finishReason: "STOP",
    }],
    usageMetadata: { promptTokenCount: 80, candidatesTokenCount: 20, thoughtsTokenCount: 30 },
  });
  assertEquals(r.content, [
    { type: "opaque", provider: "gemini", data: thought },
    { type: "text", text: "Logging." },
    {
      type: "tool_call",
      id: "gemini-2-log_water",
      name: "log_water",
      arguments: { amount_ml: 200 },
      provider_meta: { thought_signature: "SIG==" },
    },
    {
      type: "tool_call",
      id: "fc-7",
      name: "log_water",
      arguments: { amount_ml: 100 },
      provider_meta: { gemini_call_id: "fc-7" },
    },
  ]);
  assertEquals(r.stop_reason, "tool_use");
  assertEquals(r.usage, { input_tokens: 80, output_tokens: 50 });
});

Deno.test("gemini thoughtSignature round-trips through a follow-up request", () => {
  const first = geminiAdapter.parseResponse({
    candidates: [{
      content: {
        parts: [{ functionCall: { id: "abc", name: "log_water", args: { amount_ml: 1 } }, thoughtSignature: "S1" }],
      },
      finishReason: "STOP",
    }],
  });
  const body = bodyOf(
    geminiAdapter.buildRequest(
      input([
        { role: "user", content: [{ type: "text", text: "go" }] },
        { role: "assistant", content: first.content },
        { role: "user", content: [{ type: "tool_result", tool_call_id: "abc", name: "log_water", content: "{}" }] },
      ]),
      "k",
    ).init,
  );
  const contents = body.contents as { parts: Record<string, unknown>[] }[];
  assertEquals(contents[1].parts[0], {
    functionCall: { name: "log_water", args: { amount_ml: 1 }, id: "abc" },
    thoughtSignature: "S1",
  });
  assertEquals(contents[2].parts[0], { functionResponse: { name: "log_water", response: { result: {} }, id: "abc" } });
});

Deno.test("gemini response: finish reasons", () => {
  const fr = (finishReason: string) =>
    geminiAdapter.parseResponse({ candidates: [{ content: { parts: [{ text: "x" }] }, finishReason }] }).stop_reason;
  assertEquals(fr("STOP"), "end_turn");
  assertEquals(fr("MAX_TOKENS"), "max_tokens");
  assertEquals(fr("SAFETY"), "refusal");
  assertEquals(fr("RECITATION"), "refusal");
  assertEquals(fr("PROHIBITED_CONTENT"), "refusal");
  assertEquals(fr("OTHER"), "other");
  assertEquals(geminiAdapter.parseResponse({ promptFeedback: { blockReason: "SAFETY" } }).stop_reason, "refusal");
});

const gerr = (status: number, error: unknown) =>
  geminiAdapter.parseError(status, new Headers(), JSON.stringify({ error }));

Deno.test("gemini errors: RetryInfo short delay -> rate limited", () => {
  const e = gerr(429, {
    code: 429,
    status: "RESOURCE_EXHAUSTED",
    message: "Resource has been exhausted",
    details: [
      {
        "@type": "type.googleapis.com/google.rpc.QuotaFailure",
        violations: [{ quotaId: "GenerateRequestsPerMinutePerProjectPerModel" }],
      },
      { "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "12s" },
    ],
  });
  assertEquals(classifyError(e), "rate_limited");
  assertEquals(e.retryAfterMs, 12_000);
});

Deno.test("gemini errors: daily quota or long delay -> quota exhausted with cooldown", () => {
  const daily = gerr(429, {
    code: 429,
    status: "RESOURCE_EXHAUSTED",
    message: "quota",
    details: [
      {
        "@type": "type.googleapis.com/google.rpc.QuotaFailure",
        violations: [{ quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier" }],
      },
      { "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "39s" },
    ],
  });
  assertEquals(classifyError(daily), "quota_exhausted");
  assertEquals(daily.cooldownMs, 39_000);
  const long = gerr(429, {
    code: 429,
    status: "RESOURCE_EXHAUSTED",
    message: "quota",
    details: [{ "@type": "type.googleapis.com/google.rpc.RetryInfo", retryDelay: "3600s" }],
  });
  assertEquals(classifyError(long), "quota_exhausted");
  assertEquals(long.cooldownMs, 3_600_000);
});

Deno.test("gemini errors: invalid key, permission denied, unavailable, bad request", () => {
  assertEquals(
    classifyError(gerr(400, {
      code: 400,
      status: "INVALID_ARGUMENT",
      message: "API key not valid. Please pass a valid API key.",
      details: [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "API_KEY_INVALID" }],
    })),
    "invalid_credential",
  );
  assertEquals(
    classifyError(gerr(403, { code: 403, status: "PERMISSION_DENIED", message: "denied" })),
    "invalid_credential",
  );
  assertEquals(classifyError(gerr(503, { code: 503, status: "UNAVAILABLE", message: "overloaded" })), "transient");
  assertEquals(classifyError(gerr(500, { code: 500, status: "INTERNAL", message: "x" })), "transient");
  assertEquals(
    classifyError(gerr(400, { code: 400, status: "INVALID_ARGUMENT", message: "bad schema" })),
    "bad_request",
  );
  assert(gerr(400, { message: "x" }).message === "x");
});

Deno.test("gemini request: image block -> inlineData part", () => {
  const body = bodyOf(
    geminiAdapter.buildRequest(
      input([{
        role: "user",
        content: [
          { type: "text", text: "What is on this plate?" },
          { type: "image", media_type: "image/jpeg", data: "/9j/AAAA" },
        ],
      }]),
      "k",
    ).init,
  );
  assertEquals(body.contents, [{
    role: "user",
    parts: [{ text: "What is on this plate?" }, { inlineData: { mimeType: "image/jpeg", data: "/9j/AAAA" } }],
  }]);
});
