// Strict validation of the ai-chat request body (wire contract).
import {
  type Block,
  type ChatPreferences,
  type ChatRequest,
  isProviderId,
  type NormalisedMessage,
  type ProviderId,
  type ToolSpec,
} from "./providers/types.ts";
import { isPlainObject } from "./providers/util.ts";

export const LIMITS = {
  bodyBytes: 256 * 1024,
  /** Body limit when the request carries an image block. */
  bodyBytesWithImage: 1_600 * 1024,
  /** Decoded bytes per image (client downscales JPEGs to fit). */
  imageBytes: 1024 * 1024,
  imagesPerRequest: 1,
  messages: 60,
  blocksPerMessage: 40,
  textChars: 16_000,
  systemChars: 12_000,
  tools: 40,
  toolSchemaBytes: 4 * 1024,
  toolDescriptionChars: 4_000,
  idChars: 128,
  providerMetaBytes: 16 * 1024,
  maxTokens: [256, 16_000] as const,
  timeoutMs: [5_000, 120_000] as const,
  maxRetries: [0, 3] as const,
};

export const TOOL_NAME_RE = /^[a-zA-Z0-9_-]{1,64}$/;
export const REQUEST_ID_RE = /^[A-Za-z0-9_-]{8,80}$/;
export const IMAGE_MEDIA_TYPES = ["image/jpeg", "image/png", "image/webp"] as const;
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
/** Max base64 length for LIMITS.imageBytes decoded bytes. */
export const MAX_IMAGE_BASE64_CHARS = 4 * Math.ceil(LIMITS.imageBytes / 3);

export type ValidationResult =
  | { ok: true; value: ChatRequest }
  | { ok: false; path: string; message: string };

class Invalid extends Error {
  constructor(readonly path: string, message: string) {
    super(message);
  }
}

const enc = new TextEncoder();
const byteLength = (s: string) => enc.encode(s).length;

function str(v: unknown, path: string, max: number, opts: { min?: number; re?: RegExp } = {}): string {
  if (typeof v !== "string") throw new Invalid(path, "must be a string");
  if (v.length > max) throw new Invalid(path, `must be at most ${max} characters`);
  if (opts.min !== undefined && v.length < opts.min) throw new Invalid(path, `must be at least ${opts.min} characters`);
  if (opts.re && !opts.re.test(v)) throw new Invalid(path, "has an invalid format");
  return v;
}

function obj(v: unknown, path: string): Record<string, unknown> {
  if (!isPlainObject(v)) throw new Invalid(path, "must be an object");
  return v;
}

function block(v: unknown, role: NormalisedMessage["role"], path: string): Block {
  const b = obj(v, path);
  switch (b.type) {
    case "text":
      return { type: "text", text: str(b.text, `${path}.text`, LIMITS.textChars) };
    case "image": {
      if (role !== "user") throw new Invalid(`${path}.type`, "image blocks are only allowed in user messages");
      const mt = b.media_type;
      if (typeof mt !== "string" || !(IMAGE_MEDIA_TYPES as readonly string[]).includes(mt)) {
        throw new Invalid(`${path}.media_type`, "must be image/jpeg, image/png or image/webp");
      }
      if (typeof b.data !== "string" || b.data.length === 0) {
        throw new Invalid(`${path}.data`, "must be a non-empty base64 string");
      }
      if (b.data.length > MAX_IMAGE_BASE64_CHARS) {
        throw new Invalid(`${path}.data`, `must decode to at most ${LIMITS.imageBytes} bytes`);
      }
      if (b.data.length % 4 !== 0 || !BASE64_RE.test(b.data)) {
        throw new Invalid(`${path}.data`, "must be standard base64 without a data: prefix");
      }
      return { type: "image", media_type: mt as (typeof IMAGE_MEDIA_TYPES)[number], data: b.data };
    }
    case "tool_call": {
      if (role !== "assistant") {
        throw new Invalid(`${path}.type`, "tool_call blocks are only allowed in assistant messages");
      }
      const out: Block = {
        type: "tool_call",
        id: str(b.id, `${path}.id`, LIMITS.idChars, { min: 1 }),
        name: str(b.name, `${path}.name`, 64, { re: TOOL_NAME_RE }),
        arguments: obj(b.arguments ?? {}, `${path}.arguments`),
      };
      if (JSON.stringify(out.arguments).length > LIMITS.textChars) {
        throw new Invalid(`${path}.arguments`, `must serialise to at most ${LIMITS.textChars} characters`);
      }
      if (b.provider_meta !== undefined && b.provider_meta !== null) {
        const meta = obj(b.provider_meta, `${path}.provider_meta`);
        if (byteLength(JSON.stringify(meta)) > LIMITS.providerMetaBytes) {
          throw new Invalid(`${path}.provider_meta`, "is too large");
        }
        out.provider_meta = meta;
      }
      return out;
    }
    case "tool_result": {
      if (role !== "user") throw new Invalid(`${path}.type`, "tool_result blocks are only allowed in user messages");
      if (b.is_error !== undefined && typeof b.is_error !== "boolean") {
        throw new Invalid(`${path}.is_error`, "must be a boolean");
      }
      return {
        type: "tool_result",
        tool_call_id: str(b.tool_call_id, `${path}.tool_call_id`, LIMITS.idChars, { min: 1 }),
        name: str(b.name, `${path}.name`, 64, { re: TOOL_NAME_RE }),
        content: str(b.content, `${path}.content`, LIMITS.textChars),
        is_error: b.is_error === true,
      };
    }
    case "opaque": {
      if (role !== "assistant") {
        throw new Invalid(`${path}.type`, "opaque blocks are only allowed in assistant messages");
      }
      if (!isProviderId(b.provider)) throw new Invalid(`${path}.provider`, "must be anthropic, openai, gemini or groq");
      return { type: "opaque", provider: b.provider, data: obj(b.data, `${path}.data`) };
    }
    default:
      throw new Invalid(`${path}.type`, "must be text, image, tool_call, tool_result or opaque");
  }
}

function messages(v: unknown): NormalisedMessage[] {
  if (!Array.isArray(v)) throw new Invalid("messages", "must be an array");
  if (v.length === 0) throw new Invalid("messages", "must not be empty");
  if (v.length > LIMITS.messages) throw new Invalid("messages", `must contain at most ${LIMITS.messages} messages`);
  const out = v.map((m, i) => {
    const path = `messages[${i}]`;
    const o = obj(m, path);
    if (o.role !== "user" && o.role !== "assistant") throw new Invalid(`${path}.role`, "must be user or assistant");
    const role: NormalisedMessage["role"] = o.role === "user" ? "user" : "assistant";
    if (!Array.isArray(o.content)) throw new Invalid(`${path}.content`, "must be an array");
    if (o.content.length === 0) throw new Invalid(`${path}.content`, "must not be empty");
    if (o.content.length > LIMITS.blocksPerMessage) {
      throw new Invalid(`${path}.content`, `must contain at most ${LIMITS.blocksPerMessage} blocks`);
    }
    return { role, content: o.content.map((b, j) => block(b, role, `${path}.content[${j}]`)) };
  });
  const images = out.reduce((n, m) => n + m.content.filter((b) => b.type === "image").length, 0);
  if (images > LIMITS.imagesPerRequest) {
    throw new Invalid("messages", `must contain at most ${LIMITS.imagesPerRequest} image(s)`);
  }
  if (out[out.length - 1].role !== "user") {
    throw new Invalid(`messages[${out.length - 1}].role`, "the last message must be a user message");
  }
  return out;
}

function tools(v: unknown): ToolSpec[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new Invalid("tools", "must be an array");
  if (v.length > LIMITS.tools) throw new Invalid("tools", `must contain at most ${LIMITS.tools} tools`);
  const names = new Set<string>();
  return v.map((t, i) => {
    const path = `tools[${i}]`;
    const o = obj(t, path);
    const name = str(o.name, `${path}.name`, 64, { re: TOOL_NAME_RE });
    if (names.has(name)) throw new Invalid(`${path}.name`, "must be unique");
    names.add(name);
    const description = o.description === undefined
      ? ""
      : str(o.description, `${path}.description`, LIMITS.toolDescriptionChars);
    const schema = obj(o.input_schema, `${path}.input_schema`);
    if (schema.type !== undefined && schema.type !== "object") {
      throw new Invalid(`${path}.input_schema.type`, 'must be "object"');
    }
    if (byteLength(JSON.stringify(schema)) > LIMITS.toolSchemaBytes) {
      throw new Invalid(`${path}.input_schema`, `must serialise to at most ${LIMITS.toolSchemaBytes} bytes`);
    }
    return { name, description, input_schema: { type: "object", ...schema } };
  });
}

function optNumber(v: unknown, path: string): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) throw new Invalid(path, "must be a number");
  return v;
}

function optProvider(v: unknown, path: string): ProviderId | null {
  if (v === undefined || v === null) return null;
  if (!isProviderId(v)) throw new Invalid(path, "must be anthropic, openai, gemini or groq");
  return v;
}

function preferences(v: unknown): ChatPreferences {
  const empty: ChatPreferences = {
    primary_provider: null,
    model: null,
    fallback_providers: [],
    max_tokens: null,
    timeout_ms: null,
    max_retries: null,
    monthly_budget_usd: null,
  };
  if (v === undefined || v === null) return empty;
  const o = obj(v, "preferences");
  let fallback: ProviderId[] = [];
  if (o.fallback_providers !== undefined && o.fallback_providers !== null) {
    if (!Array.isArray(o.fallback_providers)) throw new Invalid("preferences.fallback_providers", "must be an array");
    if (o.fallback_providers.length > 3) {
      throw new Invalid("preferences.fallback_providers", "must contain at most 3 providers");
    }
    fallback = o.fallback_providers.map((p, i) => optProvider(p, `preferences.fallback_providers[${i}]`)!)
      .filter((p): p is ProviderId => p !== null);
  }
  const budget = optNumber(o.monthly_budget_usd, "preferences.monthly_budget_usd");
  if (budget !== null && budget < 0) throw new Invalid("preferences.monthly_budget_usd", "must be >= 0");
  return {
    primary_provider: optProvider(o.primary_provider, "preferences.primary_provider"),
    model: o.model === undefined || o.model === null ? null : str(o.model, "preferences.model", 100, { min: 1 }),
    fallback_providers: [...new Set(fallback)],
    max_tokens: optNumber(o.max_tokens, "preferences.max_tokens"),
    timeout_ms: optNumber(o.timeout_ms, "preferences.timeout_ms"),
    max_retries: optNumber(o.max_retries, "preferences.max_retries"),
    monthly_budget_usd: budget,
  };
}

export function hasImage(req: ChatRequest): boolean {
  return req.messages.some((m) => m.content.some((b) => b.type === "image"));
}

/** Validates an already size-checked, JSON-parsed body. */
export function validateChatRequest(body: unknown): ValidationResult {
  try {
    const o = obj(body, "$");
    const request_id = str(o.request_id, "request_id", 80, { re: REQUEST_ID_RE });
    const conversation_id = o.conversation_id === undefined || o.conversation_id === null
      ? null
      : str(o.conversation_id, "conversation_id", LIMITS.idChars);
    const system = o.system === undefined || o.system === null ? "" : str(o.system, "system", LIMITS.systemChars);
    return {
      ok: true,
      value: {
        request_id,
        conversation_id,
        system,
        messages: messages(o.messages),
        tools: tools(o.tools),
        preferences: preferences(o.preferences),
      },
    };
  } catch (e) {
    if (e instanceof Invalid) return { ok: false, path: e.path, message: `${e.path} ${e.message}` };
    throw e;
  }
}

export function clamp(v: number | null | undefined, [lo, hi]: readonly [number, number], dflt: number): number {
  if (typeof v !== "number" || !Number.isFinite(v)) return dflt;
  return Math.min(hi, Math.max(lo, Math.round(v)));
}

/** Reads the body enforcing the byte limit. Returns null when too large. */
export async function readBodyLimited(req: Request, limit = LIMITS.bodyBytes): Promise<string | null> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) return null;
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    buf.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder().decode(buf);
}
