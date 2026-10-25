// The only place that talks to provider HTTP APIs. Adapters stay pure.
import { anthropicAdapter } from "./anthropic.ts";
import { geminiAdapter } from "./gemini.ts";
import { groqAdapter } from "./groq.ts";
import { openaiAdapter } from "./openai.ts";
import type { ParsedResponse, ProviderAdapter, ProviderErrorInfo, ProviderId, ProviderInput } from "./types.ts";
import { redactAll } from "../redact.ts";

export const ADAPTERS: Record<ProviderId, ProviderAdapter> = {
  anthropic: anthropicAdapter,
  openai: openaiAdapter,
  gemini: geminiAdapter,
  groq: groqAdapter,
};

export function getAdapter(id: ProviderId): ProviderAdapter {
  return ADAPTERS[id];
}

export type CallResult =
  | { ok: true; response: ParsedResponse; latencyMs: number }
  | { ok: false; error: ProviderErrorInfo; latencyMs: number };

export interface CallOptions {
  timeoutMs: number;
  fetchFn?: typeof fetch;
  now?: () => number;
  /** Extra secret values to scrub from error text (the key is always scrubbed). */
  secrets?: string[];
}

export async function callProvider(
  adapter: ProviderAdapter,
  input: ProviderInput,
  apiKey: string,
  opts: CallOptions,
): Promise<CallResult> {
  const now = opts.now ?? Date.now;
  const fetchFn = opts.fetchFn ?? fetch;
  const secrets = [apiKey, ...(opts.secrets ?? [])];
  const started = now();
  const { url, init } = adapter.buildRequest(input, apiKey);
  let res: Response;
  try {
    res = await fetchFn(url, { ...init, signal: AbortSignal.timeout(Math.max(1, opts.timeoutMs)) });
  } catch (e) {
    const isTimeout = e instanceof DOMException && (e.name === "TimeoutError" || e.name === "AbortError");
    return {
      ok: false,
      latencyMs: now() - started,
      error: {
        provider: adapter.id,
        status: 0,
        kind: "transient",
        code: isTimeout ? "timeout" : "network",
        message: isTimeout
          ? `Request to ${adapter.id} timed out`
          : redactAll(`Network error contacting ${adapter.id}: ${String((e as Error)?.message ?? e)}`, secrets),
      },
    };
  }
  let text = "";
  try {
    text = await res.text();
  } catch (e) {
    const isTimeout = e instanceof DOMException && (e.name === "TimeoutError" || e.name === "AbortError");
    return {
      ok: false,
      latencyMs: now() - started,
      error: {
        provider: adapter.id,
        status: res.status,
        kind: "transient",
        code: isTimeout ? "timeout" : "network",
        message: `Failed reading ${adapter.id} response`,
      },
    };
  }
  const latencyMs = now() - started;
  if (!res.ok) {
    const info = adapter.parseError(res.status, res.headers, text);
    return { ok: false, latencyMs, error: { ...info, message: redactAll(info.message, secrets) } };
  }
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    return {
      ok: false,
      latencyMs,
      error: {
        provider: adapter.id,
        status: res.status,
        kind: "transient",
        code: "invalid_json",
        message: `${adapter.id} returned a malformed response`,
      },
    };
  }
  return { ok: true, latencyMs, response: adapter.parseResponse(json) };
}
