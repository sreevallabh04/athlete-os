// Normalised, provider-agnostic types shared by the AI proxy and its adapters.
// These mirror the wire contract used by the Flutter client (ai-chat).

export type ProviderId = "anthropic" | "openai" | "gemini";
export const PROVIDER_IDS: readonly ProviderId[] = ["anthropic", "openai", "gemini"];

export function isProviderId(v: unknown): v is ProviderId {
  return v === "anthropic" || v === "openai" || v === "gemini";
}

export type JsonObject = Record<string, unknown>;

export interface TextBlock {
  type: "text";
  text: string;
}

/** Assistant-only. */
export interface ToolCallBlock {
  type: "tool_call";
  id: string;
  name: string;
  arguments: JsonObject;
  provider_meta?: JsonObject;
}

/** User-only. `content` is JSON text (or plain text). */
export interface ToolResultBlock {
  type: "tool_result";
  tool_call_id: string;
  name: string;
  content: string;
  is_error?: boolean;
}

/** Assistant-only. Replayed verbatim to the same provider, dropped for others. */
export interface OpaqueBlock {
  type: "opaque";
  provider: ProviderId;
  data: JsonObject;
}

export type Block = TextBlock | ToolCallBlock | ToolResultBlock | OpaqueBlock;

export interface NormalisedMessage {
  role: "user" | "assistant";
  content: Block[];
}

export interface ToolSpec {
  name: string;
  description: string;
  input_schema: JsonObject;
}

export interface ChatPreferences {
  primary_provider: ProviderId | null;
  model: string | null;
  fallback_providers: ProviderId[];
  max_tokens: number | null;
  timeout_ms: number | null;
  max_retries: number | null;
  monthly_budget_usd: number | null;
}

export interface ChatRequest {
  request_id: string;
  conversation_id: string | null;
  system: string;
  messages: NormalisedMessage[];
  tools: ToolSpec[];
  preferences: ChatPreferences;
}

export type StopReason = "end_turn" | "tool_use" | "max_tokens" | "refusal" | "other";

export interface Usage {
  input_tokens: number;
  output_tokens: number;
}

/** Output of an adapter's parseResponse. */
export interface ParsedResponse {
  content: Block[];
  stop_reason: StopReason;
  usage: Usage;
}

export interface NormalisedResponse extends ParsedResponse {
  provider: ProviderId;
  model: string;
}

/** Input to an adapter's buildRequest. */
export interface ProviderInput {
  model: string;
  system: string;
  messages: NormalisedMessage[];
  tools: ToolSpec[];
  maxTokens: number;
  /** Anthropic only: output_config.effort (low|medium|high). */
  effort?: "low" | "medium" | "high";
}

export type ErrorKind =
  | "transient"
  | "rate_limited"
  | "invalid_credential"
  | "quota_exhausted"
  | "bad_request";

export interface ProviderErrorInfo {
  provider: ProviderId;
  /** HTTP status; 0 for network errors / timeouts. */
  status: number;
  /** Classification hint from the adapter (see resilience.classifyError). */
  kind?: ErrorKind;
  /** Provider error code/type, e.g. insufficient_quota, overloaded_error, timeout. */
  code?: string;
  /** Human-readable message. Always redacted before leaving the function. */
  message: string;
  /** Server-requested wait before retrying (Retry-After & friends). */
  retryAfterMs?: number;
  /** Suggested credential cooldown (quota reset), when known. */
  cooldownMs?: number;
}

export interface BuiltRequest {
  url: string;
  init: RequestInit;
}

export interface ProviderAdapter {
  id: ProviderId;
  buildRequest(input: ProviderInput, apiKey: string): BuiltRequest;
  parseResponse(json: unknown): ParsedResponse;
  parseError(status: number, headers: Headers, bodyText: string): ProviderErrorInfo;
}

export type EnvFn = (name: string) => string | undefined;
