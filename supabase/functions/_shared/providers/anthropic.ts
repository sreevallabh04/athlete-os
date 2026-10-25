// Anthropic Messages API adapter (pure: no network access).
//
// Rules enforced here:
// * never send temperature / top_p / top_k (rejected by current models);
// * tool_choice is only ever {type:"auto"} and only when tools are present;
// * never send `thinking: {type:"disabled"}` or budget_tokens;
// * thinking / redacted_thinking blocks come back as opaque blocks and are
//   replayed verbatim, in their original position.
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
import { isPlainObject, mergeConsecutive, parseRetryAfterHeader, safeJsonParse, toInt, truncate } from "./util.ts";

export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_VERSION = "2023-06-01";

type AnthropicMessage = { role: "user" | "assistant"; content: JsonObject[] };

function mapBlock(role: NormalisedMessage["role"], b: Block): JsonObject | null {
  switch (b.type) {
    case "text":
      return b.text.length > 0 ? { type: "text", text: b.text } : null;
    case "image":
      if (role !== "user") return null;
      return { type: "image", source: { type: "base64", media_type: b.media_type, data: b.data } };
    case "tool_call":
      if (role !== "assistant") return null;
      return { type: "tool_use", id: b.id, name: b.name, input: b.arguments ?? {} };
    case "tool_result":
      if (role !== "user") return null;
      return {
        type: "tool_result",
        tool_use_id: b.tool_call_id,
        content: b.content,
        is_error: b.is_error === true,
      };
    case "opaque":
      if (role !== "assistant" || b.provider !== "anthropic") return null;
      return b.data;
  }
  return null;
}

export function mapAnthropicMessages(messages: NormalisedMessage[]): AnthropicMessage[] {
  const mapped: AnthropicMessage[] = messages.map((m) => ({
    role: m.role,
    content: m.content.map((b) => mapBlock(m.role, b)).filter((x): x is JsonObject => x !== null),
  }));
  return mergeConsecutive(mapped);
}

function mapStopReason(r: unknown): StopReason {
  switch (r) {
    case "end_turn":
    case "stop_sequence":
      return "end_turn";
    case "tool_use":
      return "tool_use";
    case "max_tokens":
      return "max_tokens";
    case "refusal":
      return "refusal";
    default:
      return "other";
  }
}

const QUOTA_RE = /credit balance|spend limit|spending limit|billing|usage limit/i;

export const anthropicAdapter: ProviderAdapter = {
  id: "anthropic",

  buildRequest(input: ProviderInput, apiKey: string): BuiltRequest {
    const body: JsonObject = {
      model: input.model,
      max_tokens: input.maxTokens,
      messages: mapAnthropicMessages(input.messages),
    };
    if (input.system) body.system = input.system;
    if (input.tools.length > 0) {
      body.tools = input.tools.map((t) => ({
        name: t.name,
        description: t.description,
        input_schema: t.input_schema,
      }));
      body.tool_choice = { type: "auto" };
    }
    if (input.effort) body.output_config = { effort: input.effort };
    return {
      url: ANTHROPIC_URL,
      init: {
        method: "POST",
        headers: {
          "x-api-key": apiKey,
          "anthropic-version": ANTHROPIC_VERSION,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      },
    };
  },

  parseResponse(json: unknown): ParsedResponse {
    const j = isPlainObject(json) ? json : {};
    const raw = Array.isArray(j.content) ? j.content : [];
    const content: Block[] = [];
    for (const item of raw) {
      if (!isPlainObject(item)) continue;
      if (item.type === "text" && typeof item.text === "string") {
        content.push({ type: "text", text: item.text });
      } else if (item.type === "tool_use") {
        content.push({
          type: "tool_call",
          id: String(item.id ?? ""),
          name: String(item.name ?? ""),
          arguments: isPlainObject(item.input) ? item.input : {},
        });
      } else {
        // thinking, redacted_thinking, server tool blocks, ... -> verbatim.
        content.push({ type: "opaque", provider: "anthropic", data: item });
      }
    }
    const u = isPlainObject(j.usage) ? j.usage : {};
    return {
      content,
      stop_reason: mapStopReason(j.stop_reason),
      usage: {
        input_tokens: toInt(u.input_tokens) + toInt(u.cache_creation_input_tokens) +
          toInt(u.cache_read_input_tokens),
        output_tokens: toInt(u.output_tokens),
      },
    };
  },

  parseError(status: number, headers: Headers, bodyText: string): ProviderErrorInfo {
    const parsed = safeJsonParse(bodyText);
    const err = isPlainObject(parsed) && isPlainObject(parsed.error) ? parsed.error : {};
    const type = typeof err.type === "string" ? err.type : undefined;
    const message = typeof err.message === "string" ? err.message : truncate(bodyText || `HTTP ${status}`, 300);
    const retryAfterMs = parseRetryAfterHeader(headers.get("retry-after"));
    const base = { provider: "anthropic" as const, status, code: type, message, retryAfterMs };

    if (status === 529 || type === "overloaded_error") return { ...base, kind: "transient" };
    if (status === 429) return { ...base, kind: "rate_limited" };
    if (status === 401 || status === 403) return { ...base, kind: "invalid_credential" };
    if (status === 402 || (status === 400 && QUOTA_RE.test(message))) {
      return { ...base, kind: "quota_exhausted" };
    }
    if (status === 408 || status >= 500) return { ...base, kind: "transient" };
    return { ...base, kind: "bad_request" };
  },
};
