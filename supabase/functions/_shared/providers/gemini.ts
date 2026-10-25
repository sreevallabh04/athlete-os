// Google Gemini (generateContent, v1beta) adapter (pure: no network access).
//
// Gemini 3 models require the thought signature attached to a functionCall
// part to be sent back with that part. We surface it as
// tool_call.provider_meta.thought_signature and re-attach it on replay.
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
  ToolCallBlock,
} from "./types.ts";
import { isPlainObject, mergeConsecutive, parseDurationMs, safeJsonParse, toInt, truncate } from "./util.ts";

export const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

/**
 * Documented placeholder signature for function calls that did not originate
 * from Gemini (e.g. after a provider fallback), so validation does not fail.
 */
export const GEMINI_DUMMY_THOUGHT_SIGNATURE = "skip_thought_signature_validator";

const KEEP_KEYS = new Set([
  "type",
  "properties",
  "required",
  "enum",
  "items",
  "description",
  "minimum",
  "maximum",
  "maxLength",
  "minLength",
  "minItems",
  "maxItems",
  "nullable",
  "format",
]);
const KEEP_FORMATS = new Set(["date-time", "enum"]);

/** Reduces a JSON Schema to the OpenAPI subset accepted by Gemini. */
export function sanitizeGeminiSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(sanitizeGeminiSchema);
  if (!isPlainObject(schema)) return schema;
  const out: JsonObject = {};
  for (const [k, v] of Object.entries(schema)) {
    if (!KEEP_KEYS.has(k)) continue;
    if (k === "format") {
      if (typeof v === "string" && KEEP_FORMATS.has(v)) out.format = v;
      continue;
    }
    if (k === "type" && Array.isArray(v)) {
      const nonNull = v.filter((t) => t !== "null");
      if (nonNull.length > 0) out.type = nonNull[0];
      if (nonNull.length !== v.length) out.nullable = true;
      continue;
    }
    if (k === "properties" && isPlainObject(v)) {
      const props: JsonObject = {};
      for (const [pk, pv] of Object.entries(v)) props[pk] = sanitizeGeminiSchema(pv);
      out.properties = props;
      continue;
    }
    if (k === "items") {
      out.items = sanitizeGeminiSchema(v);
      continue;
    }
    if (k === "enum" && Array.isArray(v)) {
      out.enum = v.filter((e) => e !== null).map((e) => String(e));
      continue;
    }
    out[k] = v;
  }
  if (Array.isArray(out.required) && isPlainObject(out.properties)) {
    const props = out.properties;
    out.required = (out.required as unknown[]).filter((r) => typeof r === "string" && r in props);
  }
  return out;
}

function toolParameters(schema: JsonObject): JsonObject | undefined {
  const s = sanitizeGeminiSchema(schema) as JsonObject;
  // Gemini rejects OBJECT schemas with empty `properties`.
  if (!isPlainObject(s.properties) || Object.keys(s.properties).length === 0) return undefined;
  return s;
}

type GeminiContent = { role: "user" | "model"; parts: JsonObject[] };

export function mapGeminiContents(messages: NormalisedMessage[]): GeminiContent[] {
  // tool_call id -> gemini-native call id (when Gemini issued one) + name.
  const calls = new Map<string, ToolCallBlock>();
  for (const m of messages) {
    for (const b of m.content) if (b.type === "tool_call") calls.set(b.id, b);
  }
  const contents: GeminiContent[] = [];
  for (const m of messages) {
    const parts: JsonObject[] = [];
    let firstCallIdx = -1;
    let anySignature = false;
    for (const b of m.content) {
      switch (b.type) {
        case "text":
          if (b.text.length > 0) parts.push({ text: b.text });
          break;
        case "image":
          if (m.role === "user") parts.push({ inlineData: { mimeType: b.media_type, data: b.data } });
          break;
        case "tool_call": {
          if (m.role !== "assistant") break;
          const fc: JsonObject = { name: b.name, args: b.arguments ?? {} };
          const nativeId = b.provider_meta?.gemini_call_id;
          if (typeof nativeId === "string") fc.id = nativeId;
          const part: JsonObject = { functionCall: fc };
          const sig = b.provider_meta?.thought_signature;
          if (typeof sig === "string" && sig.length > 0) {
            part.thoughtSignature = sig;
            anySignature = true;
          }
          if (firstCallIdx < 0) firstCallIdx = parts.length;
          parts.push(part);
          break;
        }
        case "tool_result": {
          if (m.role !== "user") break;
          const call = calls.get(b.tool_call_id);
          const parsed = safeJsonParse(b.content);
          const value = parsed === undefined ? b.content : parsed;
          const fr: JsonObject = {
            name: b.name || call?.name || "tool",
            response: b.is_error ? { error: value } : { result: value },
          };
          const nativeId = call?.provider_meta?.gemini_call_id;
          if (typeof nativeId === "string") fr.id = nativeId;
          parts.push({ functionResponse: fr });
          break;
        }
        case "opaque":
          if (m.role === "assistant" && b.provider === "gemini") {
            parts.push(b.data);
            if (typeof b.data.thoughtSignature === "string") anySignature = true;
          }
          break;
      }
    }
    if (firstCallIdx >= 0 && !anySignature) {
      parts[firstCallIdx] = { ...parts[firstCallIdx], thoughtSignature: GEMINI_DUMMY_THOUGHT_SIGNATURE };
    }
    contents.push({ role: m.role === "assistant" ? "model" : "user", parts });
  }
  return mergeConsecutive(contents.map((c) => ({ ...c, content: c.parts }))).map((c) => ({
    role: c.role,
    parts: c.content,
  }));
}

function mapFinish(reason: unknown, sawCall: boolean): StopReason {
  switch (reason) {
    case "STOP":
      return sawCall ? "tool_use" : "end_turn";
    case "MAX_TOKENS":
      return "max_tokens";
    case "SAFETY":
    case "RECITATION":
    case "PROHIBITED_CONTENT":
    case "BLOCKLIST":
    case "SPII":
    case "IMAGE_SAFETY":
      return "refusal";
    case undefined:
    case null:
      return sawCall ? "tool_use" : "end_turn";
    default:
      return sawCall ? "tool_use" : "other";
  }
}

export const geminiAdapter: ProviderAdapter = {
  id: "gemini",

  buildRequest(input: ProviderInput, apiKey: string): BuiltRequest {
    const body: JsonObject = {
      contents: mapGeminiContents(input.messages),
      generationConfig: { maxOutputTokens: input.maxTokens },
    };
    if (input.system) body.systemInstruction = { parts: [{ text: input.system }] };
    if (input.tools.length > 0) {
      body.tools = [{
        functionDeclarations: input.tools.map((t) => {
          const decl: JsonObject = { name: t.name, description: t.description };
          const params = toolParameters(t.input_schema);
          if (params) decl.parameters = params;
          return decl;
        }),
      }];
    }
    return {
      url: `${GEMINI_BASE}/${encodeURIComponent(input.model)}:generateContent`,
      init: {
        method: "POST",
        headers: { "x-goog-api-key": apiKey, "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    };
  },

  parseResponse(json: unknown): ParsedResponse {
    const j = isPlainObject(json) ? json : {};
    const candidates = Array.isArray(j.candidates) ? j.candidates : [];
    const cand = isPlainObject(candidates[0]) ? candidates[0] : undefined;
    const contentObj = cand && isPlainObject(cand.content) ? cand.content : {};
    const parts = Array.isArray(contentObj.parts) ? contentObj.parts : [];
    const content: Block[] = [];
    let sawCall = false;
    parts.forEach((p, i) => {
      if (!isPlainObject(p)) return;
      if (isPlainObject(p.functionCall)) {
        sawCall = true;
        const fc = p.functionCall;
        const name = String(fc.name ?? "");
        const meta: JsonObject = {};
        if (typeof p.thoughtSignature === "string") meta.thought_signature = p.thoughtSignature;
        if (typeof fc.id === "string" && fc.id.length > 0) meta.gemini_call_id = fc.id;
        const block: ToolCallBlock = {
          type: "tool_call",
          id: typeof fc.id === "string" && fc.id.length > 0 ? fc.id : `gemini-${i}-${name}`,
          name,
          arguments: isPlainObject(fc.args) ? fc.args : {},
        };
        if (Object.keys(meta).length > 0) block.provider_meta = meta;
        content.push(block);
      } else if (typeof p.text === "string" && p.thought !== true) {
        if (p.text.length > 0) content.push({ type: "text", text: p.text });
      } else {
        content.push({ type: "opaque", provider: "gemini", data: p });
      }
    });
    let stop = mapFinish(cand?.finishReason, sawCall);
    if (!cand) {
      const fb = isPlainObject(j.promptFeedback) ? j.promptFeedback : {};
      stop = fb.blockReason ? "refusal" : "other";
    }
    const u = isPlainObject(j.usageMetadata) ? j.usageMetadata : {};
    return {
      content,
      stop_reason: stop,
      usage: {
        input_tokens: toInt(u.promptTokenCount),
        output_tokens: toInt(u.candidatesTokenCount) + toInt(u.thoughtsTokenCount),
      },
    };
  },

  parseError(status: number, _headers: Headers, bodyText: string): ProviderErrorInfo {
    const parsed = safeJsonParse(bodyText);
    const err = isPlainObject(parsed) && isPlainObject(parsed.error) ? parsed.error : {};
    const gStatus = typeof err.status === "string" ? err.status : undefined;
    const message = typeof err.message === "string" ? err.message : truncate(bodyText || `HTTP ${status}`, 300);
    const details = Array.isArray(err.details) ? err.details.filter(isPlainObject) : [];

    let retryAfterMs: number | undefined;
    let dailyQuota = false;
    let reason: string | undefined;
    for (const d of details) {
      const t = String(d["@type"] ?? "");
      if (t.endsWith("RetryInfo")) retryAfterMs = parseDurationMs(String(d.retryDelay ?? ""));
      if (t.endsWith("QuotaFailure") && Array.isArray(d.violations)) {
        for (const v of d.violations) {
          if (!isPlainObject(v)) continue;
          const id = `${v.quotaId ?? ""} ${v.quotaMetric ?? ""}`;
          if (/per_?day|daily/i.test(id)) dailyQuota = true;
        }
      }
      if (t.endsWith("ErrorInfo") && typeof d.reason === "string") reason = d.reason;
    }
    const base = { provider: "gemini" as const, status, code: reason ?? gStatus, message, retryAfterMs };

    if (status === 429 || gStatus === "RESOURCE_EXHAUSTED") {
      if (dailyQuota || (retryAfterMs !== undefined && retryAfterMs > 60_000)) {
        return { ...base, kind: "quota_exhausted", cooldownMs: retryAfterMs };
      }
      return { ...base, kind: "rate_limited" };
    }
    if (
      reason === "API_KEY_INVALID" || /API key not valid|API key expired/i.test(message) ||
      status === 401 || status === 403 || gStatus === "PERMISSION_DENIED" || gStatus === "UNAUTHENTICATED"
    ) {
      return { ...base, kind: "invalid_credential" };
    }
    if (status === 408 || status >= 500 || gStatus === "UNAVAILABLE" || gStatus === "DEADLINE_EXCEEDED") {
      return { ...base, kind: "transient" };
    }
    return { ...base, kind: "bad_request" };
  },
};
