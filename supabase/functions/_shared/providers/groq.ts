// Groq adapter: OpenAI-compatible Chat Completions (pure: no network access).
//
// POST https://api.groq.com/openai/v1/chat/completions, Bearer auth.
// * tools: [{type:"function", function:{name, description, parameters}}]
// * assistant tool calls come back in message.tool_calls (arguments = JSON text)
// * tool results are sent as {role:"tool", tool_call_id, name, content}
// * reasoning models (openai/gpt-oss-*) return message.reasoning — dropped;
//   Groq does not need it replayed.
// * image blocks are not sent (text placeholder) — the default Groq models are
//   text-only.
// Rate limits: retry-after (seconds, 429 only) and x-ratelimit-{limit,remaining,
// reset}-{requests,tokens}; "requests" is per DAY, "tokens" per MINUTE.
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
import {
  IMAGE_PLACEHOLDER,
  isPlainObject,
  parseDurationMs,
  parseRetryAfterHeader,
  safeJsonParse,
  toInt,
  truncate,
} from "./util.ts";

export const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";

type ChatMessage = JsonObject & { role: "system" | "user" | "assistant" | "tool" };

/** Normalised messages -> OpenAI Chat Completions messages (system first). */
export function mapGroqMessages(system: string, messages: NormalisedMessage[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  if (system) out.push({ role: "system", content: system });
  for (const m of messages) {
    if (m.role === "assistant") {
      const texts: string[] = [];
      const calls: JsonObject[] = [];
      for (const b of m.content) {
        if (b.type === "text" && b.text.length > 0) texts.push(b.text);
        if (b.type === "tool_call") {
          calls.push({
            id: b.id,
            type: "function",
            function: { name: b.name, arguments: JSON.stringify(b.arguments ?? {}) },
          });
        }
        // opaque blocks of other providers are dropped
      }
      if (texts.length === 0 && calls.length === 0) continue;
      const msg: ChatMessage = { role: "assistant", content: texts.length > 0 ? texts.join("\n\n") : null };
      if (calls.length > 0) msg.tool_calls = calls;
      out.push(msg);
      continue;
    }
    // user: tool results must directly follow the assistant tool_calls, so
    // they are emitted first, then any user text in one user message.
    const texts: string[] = [];
    for (const b of m.content) {
      if (b.type === "tool_result") {
        out.push({
          role: "tool",
          tool_call_id: b.tool_call_id,
          name: b.name,
          content: b.is_error ? JSON.stringify({ error: safeJsonParse(b.content) ?? b.content }) : b.content,
        });
      } else if (b.type === "text" && b.text.length > 0) {
        texts.push(b.text);
      } else if (b.type === "image") {
        texts.push(IMAGE_PLACEHOLDER);
      }
    }
    if (texts.length > 0) {
      const last = out[out.length - 1];
      if (last && last.role === "user" && typeof last.content === "string") {
        last.content = `${last.content}\n\n${texts.join("\n\n")}`;
      } else {
        out.push({ role: "user", content: texts.join("\n\n") });
      }
    }
  }
  return out;
}

function mapFinish(reason: unknown, sawCall: boolean): StopReason {
  if (sawCall) return "tool_use";
  switch (reason) {
    case "stop":
      return "end_turn";
    case "tool_calls":
      return "tool_use";
    case "length":
      return "max_tokens";
    case "content_filter":
      return "refusal";
    case undefined:
    case null:
      return "end_turn";
    default:
      return "other";
  }
}

/** Long (daily) limits put the key in cooldown instead of retrying. */
const DAILY_HINT_MS = 60_000;

export const groqAdapter: ProviderAdapter = {
  id: "groq",

  buildRequest(input: ProviderInput, apiKey: string): BuiltRequest {
    const body: JsonObject = {
      model: input.model,
      messages: mapGroqMessages(input.system, input.messages),
      max_completion_tokens: input.maxTokens,
    };
    if (input.tools.length > 0) {
      body.tools = input.tools.map((t) => ({
        type: "function",
        function: { name: t.name, description: t.description, parameters: t.input_schema },
      }));
      body.tool_choice = "auto";
    }
    return {
      url: GROQ_URL,
      init: {
        method: "POST",
        headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    };
  },

  parseResponse(json: unknown): ParsedResponse {
    const j = isPlainObject(json) ? json : {};
    const choices = Array.isArray(j.choices) ? j.choices : [];
    const choice = isPlainObject(choices[0]) ? choices[0] : {};
    const msg = isPlainObject(choice.message) ? choice.message : {};
    const content: Block[] = [];
    if (typeof msg.content === "string" && msg.content.length > 0) {
      content.push({ type: "text", text: msg.content });
    }
    let sawCall = false;
    const calls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];
    calls.forEach((c, i) => {
      if (!isPlainObject(c)) return;
      const fn = isPlainObject(c.function) ? c.function : {};
      const name = String(fn.name ?? "");
      const rawArgs = typeof fn.arguments === "string" ? fn.arguments : "";
      const parsed = isPlainObject(fn.arguments) ? fn.arguments : rawArgs === "" ? {} : safeJsonParse(rawArgs);
      sawCall = true;
      const block: Block = {
        type: "tool_call",
        id: typeof c.id === "string" && c.id.length > 0 ? c.id : `groq-${i}-${name}`,
        name,
        arguments: isPlainObject(parsed) ? parsed : {},
      };
      if (!isPlainObject(parsed)) block.provider_meta = { raw_arguments: rawArgs };
      content.push(block);
    });
    const u = isPlainObject(j.usage) ? j.usage : {};
    return {
      content,
      stop_reason: mapFinish(choice.finish_reason, sawCall),
      usage: { input_tokens: toInt(u.prompt_tokens), output_tokens: toInt(u.completion_tokens) },
    };
  },

  parseError(status: number, headers: Headers, bodyText: string): ProviderErrorInfo {
    const parsed = safeJsonParse(bodyText);
    const err = isPlainObject(parsed) && isPlainObject(parsed.error) ? parsed.error : {};
    const code = typeof err.code === "string" ? err.code : typeof err.type === "string" ? err.type : undefined;
    const message = typeof err.message === "string" ? err.message : truncate(bodyText || `HTTP ${status}`, 300);
    const retryAfterMs = groqRetryAfterMs(headers);
    const base = { provider: "groq" as const, status, code, message, retryAfterMs };

    if (status === 413 || /request too large/i.test(message)) {
      // A single request bigger than the tokens-per-minute allowance (or the
      // context window). Retrying the same request cannot succeed.
      return { ...base, kind: "request_too_large" };
    }
    if (status === 429) {
      const dailyExhausted = headers.get("x-ratelimit-remaining-requests")?.trim() === "0" ||
        /per day|\(RPD\)|\(TPD\)/i.test(message);
      if (dailyExhausted || (retryAfterMs !== undefined && retryAfterMs > DAILY_HINT_MS)) {
        const reset = parseDurationMs(headers.get("x-ratelimit-reset-requests"));
        return {
          ...base,
          kind: "quota_exhausted",
          cooldownMs: dailyExhausted ? reset ?? retryAfterMs : retryAfterMs ?? reset,
        };
      }
      return { ...base, kind: "rate_limited" };
    }
    if (status === 401 || status === 403 || code === "invalid_api_key") return { ...base, kind: "invalid_credential" };
    // Model produced a malformed tool call; a retry usually succeeds.
    if (code === "tool_use_failed") return { ...base, kind: "transient" };
    // 498 = Groq flex-tier capacity exceeded.
    if (status === 408 || status === 409 || status === 498 || status >= 500) return { ...base, kind: "transient" };
    return { ...base, kind: "bad_request" };
  },
};

function groqRetryAfterMs(headers: Headers): number | undefined {
  const ra = parseRetryAfterHeader(headers.get("retry-after"));
  if (ra !== undefined) return ra;
  if (headers.get("x-ratelimit-remaining-tokens")?.trim() === "0") {
    return parseDurationMs(headers.get("x-ratelimit-reset-tokens"));
  }
  if (headers.get("x-ratelimit-remaining-requests")?.trim() === "0") {
    return parseDurationMs(headers.get("x-ratelimit-reset-requests"));
  }
  return undefined;
}
