// ai-chat: authenticated, budgeted, rate-limited, multi-provider LLM proxy.
// All dependencies are injected so the full flow is unit-testable; index.ts
// wires the Supabase-backed implementations.
import {
  allowedModels,
  checkBudget,
  costUsd,
  effectiveUserBudget,
  globalBudgetUsd,
  loadPriceTable,
  monthStartUtc,
  type PriceTable,
  providerForModel,
} from "../_shared/budget.ts";
import { type Credential, defaultModel, loadCredentials, providerOrder } from "../_shared/credentials.ts";
import { errorResponse, handleOptions, jsonResponse } from "../_shared/http.ts";
import { callProvider, getAdapter } from "../_shared/providers/call.ts";
import {
  type ChatRequest,
  type EnvFn,
  IMAGE_CAPABLE_PROVIDERS,
  type ProviderId,
  type ProviderInput,
} from "../_shared/providers/types.ts";
import { checkRateLimit, rateLimitPerMin, type RateLimitStore } from "../_shared/ratelimit.ts";
import { redactAll } from "../_shared/redact.ts";
import {
  BreakerRegistry,
  type BreakerStore,
  type Clock,
  DEFAULT_DEADLINE_MS,
  type HealthStore,
  type ProviderPlan,
  runWithFallback,
} from "../_shared/resilience.ts";
import {
  CACHE_TTL_MS,
  type ResponseCache,
  type UsageRow,
  type UsageStore,
  type UserSettings,
  type UserSettingsStore,
} from "../_shared/stores.ts";
import { clamp, hasImage, LIMITS, readBodyLimited, validateChatRequest } from "../_shared/validate.ts";

export interface ChatDeps {
  env: EnvFn;
  /** Returns the user id or throws (any error -> 401). */
  authenticate: (req: Request) => Promise<string>;
  cache: ResponseCache;
  rateLimits: RateLimitStore;
  usage: UsageStore;
  userSettings: UserSettingsStore;
  health: HealthStore;
  breakerStore: BreakerStore | null;
  fetchFn: typeof fetch;
  clock: Clock;
  log: (event: Record<string, unknown>) => void;
}

export const DEFAULTS = { maxTokens: 4096, timeoutMs: 60_000, maxRetries: 2 };

export function resolveSettings(req: ChatRequest, stored: UserSettings | null) {
  const p = req.preferences;
  const maxTokens = clamp(p.max_tokens ?? stored?.max_tokens, LIMITS.maxTokens, DEFAULTS.maxTokens);
  const timeoutMs = clamp(p.timeout_ms ?? stored?.timeout_ms, LIMITS.timeoutMs, DEFAULTS.timeoutMs);
  const maxRetries = clamp(p.max_retries, LIMITS.maxRetries, DEFAULTS.maxRetries);
  const attempts = Math.min(3, 1 + maxRetries);
  return {
    maxTokens,
    timeoutMs,
    attempts,
    primary: p.primary_provider ?? stored?.primary_provider ?? null,
    fallback: p.fallback_providers.length > 0 ? p.fallback_providers : stored?.fallback_providers ?? [],
    model: p.model ?? stored?.model ?? null,
  };
}

/** primary -> fallback prefs -> AI_PROVIDER_ORDER, configured providers only; model pref applies to its own provider. */
export function buildPlan(
  env: EnvFn,
  credentials: Credential[],
  primary: ProviderId | null,
  fallback: ProviderId[],
  modelPref: string | null,
  table: PriceTable,
): ProviderPlan[] {
  const configured = new Set(credentials.map((c) => c.provider));
  const order: ProviderId[] = [];
  for (const p of [primary, ...fallback, ...providerOrder(env)]) {
    if (p && configured.has(p) && !order.includes(p)) order.push(p);
  }
  const modelProvider = modelPref ? providerForModel(modelPref, env, table) : undefined;
  return order.map((provider) => ({
    provider,
    model: modelPref && modelProvider === provider && allowedModels(provider, env, table).includes(modelPref)
      ? modelPref
      : defaultModel(provider, env),
  }));
}

function effortFromEnv(env: EnvFn): ProviderInput["effort"] {
  const e = env("AI_ANTHROPIC_EFFORT")?.trim().toLowerCase();
  return e === "low" || e === "medium" || e === "high" ? e : undefined;
}

/** Usage bookkeeping after a provider call must not turn a paid answer into an error. */
async function recordSafely(deps: ChatDeps, secrets: string[], row: UsageRow): Promise<void> {
  try {
    await deps.usage.record(row);
  } catch (e) {
    deps.log({ event: "usage_record_failed", request_id: row.request_id, error: redactAll(String(e), secrets) });
  }
}

export function createChatHandler(deps: ChatDeps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const pre = handleOptions(req);
    if (pre) return pre;
    if (req.method !== "POST") return errorResponse("invalid_request", "Use POST.");

    let userId: string;
    try {
      userId = await deps.authenticate(req);
    } catch {
      return errorResponse("unauthorized", "Please sign in to use the AI coach.");
    }

    const credentials = loadCredentials(deps.env);
    const secrets = credentials.map((c) => c.key);
    let requestId: string | undefined;
    try {
      // ---- parse & validate -------------------------------------------------
      // Read up to the image limit; text-only bodies are held to LIMITS.bodyBytes below.
      const raw = await readBodyLimited(req, LIMITS.bodyBytesWithImage);
      if (raw === null) {
        return errorResponse("invalid_request", `Request body exceeds ${LIMITS.bodyBytesWithImage} bytes.`);
      }
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        return errorResponse("invalid_request", "Request body must be valid JSON.");
      }
      const v = validateChatRequest(body);
      if (!v.ok) return errorResponse("invalid_request", v.message);
      const chat = v.value;
      requestId = chat.request_id;
      if (!hasImage(chat) && new TextEncoder().encode(raw).length > LIMITS.bodyBytes) {
        return errorResponse("invalid_request", `Request body exceeds ${LIMITS.bodyBytes} bytes.`);
      }

      // ---- idempotency ------------------------------------------------------
      const cached = await deps.cache.get(chat.request_id);
      if (cached) {
        if (cached.user_id !== userId) {
          return errorResponse("conflict", "This request_id is already in use.");
        }
        if (deps.clock.now() - Date.parse(cached.created_at) < CACHE_TTL_MS) {
          const resp = cached.response as Record<string, unknown>;
          const prevMeta = (resp.meta ?? {}) as Record<string, unknown>;
          const meta = { ...prevMeta, cached: true };
          deps.log({ event: "ai_chat", request_id: chat.request_id, status: "cached" });
          return jsonResponse(200, { ...resp, meta });
        }
      }

      // ---- rate limit -------------------------------------------------------
      const rl = await checkRateLimit(deps.rateLimits, userId, "ai-chat", rateLimitPerMin(deps.env), deps.clock.now());
      if (!rl.allowed) {
        return errorResponse("rate_limited", "Too many AI requests. Please wait a moment.", rl.retryAfterS);
      }

      if (credentials.length === 0) {
        return errorResponse("no_provider_configured", "The AI coach is not configured on the server yet.");
      }

      // ---- budget -----------------------------------------------------------
      const stored = await deps.userSettings.get(userId);
      const monthStart = monthStartUtc(new Date(deps.clock.now()));
      const [userSpend, globalSpend] = await Promise.all([
        deps.usage.monthSpend(userId, monthStart),
        deps.usage.globalMonthSpend(monthStart),
      ]);
      const globalBudget = globalBudgetUsd(deps.env);
      const userBudget = effectiveUserBudget(
        chat.preferences.monthly_budget_usd,
        stored?.monthly_budget_usd,
        globalBudget,
      );
      const budget = checkBudget({ userSpend, globalSpend, userBudget, globalBudget });
      if (!budget.allowed) {
        await deps.usage.record({
          user_id: userId,
          request_id: chat.request_id,
          provider: null,
          model: null,
          credential_alias: null,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: 0,
          status: "refused",
          latency_ms: null,
        });
        deps.log({ event: "ai_chat", request_id: chat.request_id, status: "budget_exceeded" });
        return errorResponse("budget_exceeded", budget.reason ?? "Monthly AI budget reached.");
      }

      // ---- provider plan ----------------------------------------------------
      const table = loadPriceTable(deps.env);
      const s = resolveSettings(chat, stored);
      const withImage = hasImage(chat);
      const plan = buildPlan(deps.env, credentials, s.primary, s.fallback, s.model, table)
        .filter((p) => !withImage || IMAGE_CAPABLE_PROVIDERS.includes(p.provider));
      if (plan.length === 0) {
        return errorResponse("no_provider_configured", "No configured AI provider can analyse images.");
      }
      const totalDeadlineMs = Math.min(
        s.timeoutMs,
        Number(deps.env("AI_TOTAL_DEADLINE_MS")) > 0 ? Number(deps.env("AI_TOTAL_DEADLINE_MS")) : DEFAULT_DEADLINE_MS,
      );
      const started = deps.clock.now();
      const effort = effortFromEnv(deps.env);

      const result = await runWithFallback({
        plan,
        credentials,
        health: deps.health,
        breakers: new BreakerRegistry(deps.breakerStore),
        attemptsPerCredential: s.attempts,
        deadlineAt: started + totalDeadlineMs,
        clock: deps.clock,
        log: (e) => deps.log({ ...e, request_id: chat.request_id }),
        invoke: (p, cred, remainingMs) =>
          callProvider(
            getAdapter(p.provider),
            {
              model: p.model,
              system: chat.system,
              messages: chat.messages,
              tools: chat.tools,
              maxTokens: s.maxTokens,
              effort: p.provider === "anthropic" ? effort : undefined,
            },
            cred.key,
            {
              timeoutMs: Math.min(s.timeoutMs, remainingMs),
              fetchFn: deps.fetchFn,
              now: deps.clock.now,
              secrets,
            },
          ),
      });
      const latency = deps.clock.now() - started;

      if (!result.ok) {
        await recordSafely(deps, secrets, {
          user_id: userId,
          request_id: chat.request_id,
          provider: result.provider ?? null,
          model: result.model ?? null,
          credential_alias: result.alias ?? null,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: 0,
          status: "error",
          latency_ms: latency,
        });
        deps.log({
          event: "ai_chat",
          request_id: chat.request_id,
          provider: result.provider,
          alias: result.alias,
          status: result.code,
          latency_ms: latency,
        });
        return errorResponse(result.code, redactAll(result.message, secrets), result.retryAfterS);
      }

      const cost = costUsd(result.model, result.response.usage, table);
      const monthSpend = Math.round((userSpend + cost) * 1e6) / 1e6;
      const after = checkBudget({ userSpend: monthSpend, globalSpend: globalSpend + cost, userBudget, globalBudget });
      const response = {
        request_id: chat.request_id,
        content: result.response.content,
        stop_reason: result.response.stop_reason,
        usage: {
          input_tokens: result.response.usage.input_tokens,
          output_tokens: result.response.usage.output_tokens,
          cost_usd: cost,
        },
        provider: result.provider,
        model: result.model,
        meta: {
          cached: false,
          fallback_used: result.fallbackUsed,
          attempts: result.attempts,
          budget: {
            month_spend_usd: monthSpend,
            monthly_budget_usd: userBudget,
            percent: after.percent,
            alerts: after.alerts,
          },
        },
      };
      await recordSafely(deps, secrets, {
        user_id: userId,
        request_id: chat.request_id,
        provider: result.provider,
        model: result.model,
        credential_alias: result.alias,
        input_tokens: result.response.usage.input_tokens,
        output_tokens: result.response.usage.output_tokens,
        cost_usd: cost,
        status: "ok",
        latency_ms: latency,
      });
      try {
        await deps.cache.put(chat.request_id, userId, response);
      } catch (e) {
        deps.log({ event: "cache_put_failed", request_id: chat.request_id, error: redactAll(String(e), secrets) });
      }
      deps.log({
        event: "ai_chat",
        request_id: chat.request_id,
        provider: result.provider,
        alias: result.alias,
        status: "ok",
        latency_ms: latency,
      });
      return jsonResponse(200, response);
    } catch (e) {
      deps.log({ event: "ai_chat_internal_error", request_id: requestId, error: redactAll(String(e), secrets) });
      return errorResponse("internal", "Something went wrong. Please try again.");
    }
  };
}
