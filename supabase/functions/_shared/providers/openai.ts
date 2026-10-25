// OpenAI Responses API adapter (pure: no network access).
//
// store:false + include reasoning.encrypted_content so reasoning items can be
// replayed statelessly; they come back as opaque blocks and are replayed in
// their original position.
import type {
  Block,
  BuiltRequest,
  JsonObject,
  NormalisedMessage,
  ParsedResponse,
  ProviderAdapter,
  ProviderErrorInfo,
  ProviderInput,
  StopReason,
} from "./types.ts";
import { isPlainObject, parseDurationMs, parseRetryAfterHeader, safeJsonParse, toInt, truncate } from "./util.ts";

export const OPENAI_URL = "https://api.openai.com/v1/responses";

export function mapOpenAIInput(messages: NormalisedMessage[]): JsonObject[] {
  const items: JsonObject[] = [];
  for (const m of messages) {
    let parts: JsonObject[] = [];
    const flush = () => {
      if (parts.length > 0) {
        items.push({ role: m.role, content: parts });
        parts = [];
      }
    };
    for (const b of m.content) {
      switch (b.type) {
        case "text":
          if (b.text.length === 0) break;
          parts.push({ type: m.role === "user" ? "input_text" : "output_text", text: b.text });
          break;
        case "tool_call":
          if (m.role !== "assistant") break;
          flush();
          items.push({
            type: "function_call",
            call_id: b.id,
            name: b.name,
            arguments: JSON.stringify(b.arguments ?? {}),
          });
          break;
        case "tool_result":
          if (m.role !== "user") break;
          flush();
          items.push({ type: "function_call_output", call_id: b.tool_call_id, output: b.content });
          break;
        case "opaque":
          if (m.role !== "assistant" || b.provider !== "openai") break;
          flush();
          items.push(b.data);
          break;
      }
    }
    flush();
  }
  return items;
}

export const openaiAdapter: ProviderAdapter = {
  id: "openai",

  buildRequest(input: ProviderInput, apiKey: string): BuiltRequest {
    const body: JsonObject = {
      model: input.model,
      input: mapOpenAIInput(input.messages),
      max_output_tokens: input.maxTokens,
      store: false,
      include: ["reasoning.encrypted_content"],
    };
    if (input.system) body.instructions = input.system;
    if (input.tools.length > 0) {
      body.tools = input.tools.map((t) => ({
        type: "function",
        name: t.name,
        description: t.description,
        parameters: t.input_schema,
        // Responses API defaults to strict mode, which requires every schema
        // to be closed/fully-required. Our tool schemas are not, so opt out.
        strict: false,
      }));
      body.tool_choice = "auto";
    }
    return {
      url: OPENAI_URL,
      init: {
        method: "POST",
        headers: {
          "authorization": `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      },
    };
  },

  parseResponse(json: unknown): ParsedResponse {
    const j = isPlainObject(json) ? json : {};
    const output = Array.isArray(j.output) ? j.output : [];
    const content: Block[] = [];
    let sawCall = false;
    let sawRefusal = false;
    for (const item of output) {
      if (!isPlainObject(item)) continue;
      if (item.type === "message") {
        const parts = Array.isArray(item.content) ? item.content : [];
        const texts: string[] = [];
        for (const p of parts) {
          if (!isPlainObject(p)) continue;
          if (p.type === "output_text" && typeof p.text === "string") texts.push(p.text);
          if (p.type === "refusal" && typeof p.refusal === "string") {
            texts.push(p.refusal);
            sawRefusal = true;
          }
        }
        const text = texts.join("");
        if (text.length > 0) content.push({ type: "text", text });
      } else if (item.type === "function_call") {
        sawCall = true;
        const rawArgs = typeof item.arguments === "string" ? item.arguments : "";
        const parsed = rawArgs === "" ? {} : safeJsonParse(rawArgs);
        const block: Block = {
          type: "tool_call",
          id: String(item.call_id ?? item.id ?? ""),
          name: String(item.name ?? ""),
          arguments: isPlainObject(parsed) ? parsed : {},
        };
        if (!isPlainObject(parsed)) block.provider_meta = { raw_arguments: rawArgs };
        content.push(block);
      } else {
        content.push({ type: "opaque", provider: "openai", data: item });
      }
    }
    let stop: StopReason = "end_turn";
    const incomplete = isPlainObject(j.incomplete_details) ? j.incomplete_details : {};
    if (sawCall) stop = "tool_use";
    else if (j.status === "incomplete" && incomplete.reason === "max_output_tokens") stop = "max_tokens";
    else if (j.status === "incomplete" && incomplete.reason === "content_filter") stop = "refusal";
    else if (sawRefusal) stop = "refusal";
    else if (j.status === "incomplete") stop = "other";
    const u = isPlainObject(j.usage) ? j.usage : {};
    return {
      content,
      stop_reason: stop,
      usage: { input_tokens: toInt(u.input_tokens), output_tokens: toInt(u.output_tokens) },
    };
  },

  parseError(status: number, headers: Headers, bodyText: string): ProviderErrorInfo {
    const parsed = safeJsonParse(bodyText);
    const err = isPlainObject(parsed) && isPlainObject(parsed.error) ? parsed.error : {};
    const code = typeof err.code === "string" ? err.code : typeof err.type === "string" ? err.type : undefined;
    const message = typeof err.message === "string" ? err.message : truncate(bodyText || `HTTP ${status}`, 300);
    const retryAfterMs = parseRetryAfterMs(headers);
    const base = { provider: "openai" as const, status, code, message, retryAfterMs };

    if (status === 429) {
      if (code === "insufficient_quota" || err.type === "insufficient_quota") {
        return { ...base, kind: "quota_exhausted" };
      }
      return { ...base, kind: "rate_limited" };
    }
    if (status === 401 || status === 403) return { ...base, kind: "invalid_credential" };
    if (status === 402) return { ...base, kind: "quota_exhausted" };
    if (status === 408 || status === 409 || status >= 500) return { ...base, kind: "transient" };
    return { ...base, kind: "bad_request" };
  },
};

function parseRetryAfterMs(headers: Headers): number | undefined {
  const ms = headers.get("retry-after-ms");
  if (ms && /^\d+(\.\d+)?$/.test(ms.trim())) return Math.round(Number(ms));
  const ra = parseRetryAfterHeader(headers.get("retry-after"));
  if (ra !== undefined) return ra;
  return parseDurationMs(headers.get("x-ratelimit-reset-requests"));
}
