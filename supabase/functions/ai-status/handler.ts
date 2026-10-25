// ai-status: provider/credential health, limits and month-to-date usage
// (GET or POST {action:"status"}), plus live credential tests
// (POST {action:"test", provider?}). Never returns key material.
import {
  allowedModels,
  cheapestModel,
  checkBudget,
  costUsd,
  effectiveUserBudget,
  globalBudgetUsd,
  loadPriceTable,
  monthStartUtc,
} from "../_shared/budget.ts";
import { ALIASES, defaultModel, loadCredentials, providerOrder } from "../_shared/credentials.ts";
import { errorResponse, handleOptions, jsonResponse } from "../_shared/http.ts";
import { callProvider, getAdapter } from "../_shared/providers/call.ts";
import { type EnvFn, isProviderId, PROVIDER_IDS, type ProviderId } from "../_shared/providers/types.ts";
import { isPlainObject } from "../_shared/providers/util.ts";
import { checkRateLimit, rateLimitPerMin, type RateLimitStore } from "../_shared/ratelimit.ts";
import { redactAll } from "../_shared/redact.ts";
import {
  BreakerRegistry,
  type BreakerStore,
  classifyError,
  type Clock,
  DEFAULT_QUOTA_COOLDOWN_MS,
  DEFAULT_RATE_LIMIT_COOLDOWN_MS,
  type HealthStore,
  isLongRateLimit,
} from "../_shared/resilience.ts";
import type { UsageStore, UserSettingsStore } from "../_shared/stores.ts";
import { LIMITS, readBodyLimited } from "../_shared/validate.ts";

export interface StatusDeps {
  env: EnvFn;
  authenticate: (req: Request) => Promise<string>;
  rateLimits: RateLimitStore;
  usage: UsageStore;
  userSettings: UserSettingsStore;
  health: HealthStore;
  breakerStore: BreakerStore | null;
  fetchFn: typeof fetch;
  clock: Clock;
  log: (event: Record<string, unknown>) => void;
  /** Random suffix for synthetic request ids. */
  randomId?: () => string;
}

export const TEST_RATE_LIMIT_PER_MIN = 5;
export const STATUS_BODY_LIMIT_BYTES = 4096;
const TEST_TIMEOUT_MS = 20_000;

export function createStatusHandler(deps: StatusDeps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const pre = handleOptions(req);
    if (pre) return pre;
    if (req.method !== "GET" && req.method !== "POST") return errorResponse("invalid_request", "Use GET or POST.");

    let userId: string;
    try {
      userId = await deps.authenticate(req);
    } catch {
      return errorResponse("unauthorized", "Please sign in.");
    }
    const secrets = loadCredentials(deps.env).map((c) => c.key);

    try {
      let action = "status";
      let provider: ProviderId | undefined;
      if (req.method === "POST") {
        // Stream with a byte cap: never buffer an arbitrarily large body.
        const text = await readBodyLimited(req, STATUS_BODY_LIMIT_BYTES);
        if (text === null) return errorResponse("invalid_request", "Request body is too large.");
        let body: unknown = {};
        if (text.trim()) {
          try {
            body = JSON.parse(text);
          } catch {
            return errorResponse("invalid_request", "Request body must be valid JSON.");
          }
        }
        if (!isPlainObject(body)) return errorResponse("invalid_request", "Request body must be an object.");
        if (body.action !== undefined) {
          if (body.action !== "status" && body.action !== "test") {
            return errorResponse("invalid_request", 'action must be "status" or "test".');
          }
          action = body.action;
        }
        if (body.provider !== undefined && body.provider !== null) {
          if (!isProviderId(body.provider)) {
            return errorResponse("invalid_request", "provider must be anthropic, openai, gemini or groq.");
          }
          provider = body.provider;
        }
      }
      return action === "test" ? await runTests(deps, userId, provider, secrets) : await status(deps, userId);
    } catch (e) {
      deps.log({ event: "ai_status_internal_error", error: redactAll(String(e), secrets) });
      return errorResponse("internal", "Something went wrong. Please try again.");
    }
  };
}

async function status(deps: StatusDeps, userId: string): Promise<Response> {
  const env = deps.env;
  const creds = loadCredentials(env);
  const table = loadPriceTable(env);
  const healthRows = await deps.health.list();
  const breakers = new BreakerRegistry(deps.breakerStore);

  const providers = [];
  for (const p of PROVIDER_IDS) {
    const configuredAliases = ALIASES.filter((a) => creds.some((c) => c.provider === p && c.alias === a));
    const breaker = await breakers.get(p);
    providers.push({
      provider: p,
      configured: configuredAliases.length > 0,
      default_model: defaultModel(p, env),
      allowed_models: allowedModels(p, env, table),
      circuit: breaker.state,
      aliases: configuredAliases.map((alias) => {
        const h = healthRows.find((r) => r.provider === p && r.alias === alias);
        return {
          alias,
          status: h?.status ?? "ok",
          cooldown_until: h?.cooldown_until ?? null,
          consecutive_failures: h?.consecutive_failures ?? 0,
          last_error: h?.last_error ? redactAll(h.last_error, creds.map((c) => c.key)) : null,
        };
      }),
    });
  }

  const now = new Date(deps.clock.now());
  const monthStart = monthStartUtc(now);
  const [usage, globalSpend, stored] = await Promise.all([
    deps.usage.monthUsage(userId, monthStart),
    deps.usage.globalMonthSpend(monthStart),
    deps.userSettings.get(userId),
  ]);
  const globalBudget = globalBudgetUsd(env);
  const userBudget = effectiveUserBudget(null, stored?.monthly_budget_usd, globalBudget);
  const budget = checkBudget({ userSpend: usage.cost_usd, globalSpend, userBudget, globalBudget });

  return jsonResponse(200, {
    providers,
    provider_order: providerOrder(env),
    limits: {
      max_tokens: [...LIMITS.maxTokens],
      timeout_ms: [...LIMITS.timeoutMs],
      max_retries: [0, 2],
      rate_limit_per_min: rateLimitPerMin(env),
    },
    usage: {
      month_start: monthStart.toISOString().slice(0, 10),
      requests: usage.requests,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cost_usd: Math.round(usage.cost_usd * 1e6) / 1e6,
      monthly_budget_usd: userBudget,
      global_budget_usd: globalBudget,
      percent: budget.percent,
      alerts: budget.alerts,
    },
  });
}

async function runTests(
  deps: StatusDeps,
  userId: string,
  only: ProviderId | undefined,
  secrets: string[],
): Promise<Response> {
  const env = deps.env;
  const rl = await checkRateLimit(deps.rateLimits, userId, "ai-status-test", TEST_RATE_LIMIT_PER_MIN, deps.clock.now());
  if (!rl.allowed) {
    return errorResponse("rate_limited", "Too many provider tests. Please wait a moment.", rl.retryAfterS);
  }

  const creds = loadCredentials(env).filter((c) => !only || c.provider === only);
  if (creds.length === 0) {
    return errorResponse("no_provider_configured", "No AI provider credential is configured on the server.");
  }

  const monthStart = monthStartUtc(new Date(deps.clock.now()));
  const [userSpend, globalSpend, stored] = await Promise.all([
    deps.usage.monthSpend(userId, monthStart),
    deps.usage.globalMonthSpend(monthStart),
    deps.userSettings.get(userId),
  ]);
  const globalBudget = globalBudgetUsd(env);
  const budget = checkBudget({
    userSpend,
    globalSpend,
    userBudget: effectiveUserBudget(null, stored?.monthly_budget_usd, globalBudget),
    globalBudget,
  });
  if (!budget.allowed) return errorResponse("budget_exceeded", budget.reason ?? "Monthly AI budget reached.");

  const table = loadPriceTable(env);
  const randomId = deps.randomId ?? (() => crypto.randomUUID().replaceAll("-", ""));
  const results = await Promise.all(creds.map(async (cred) => {
    const model = cheapestModel(cred.provider, env, table);
    const h = await deps.health.get(cred.provider, cred.alias).catch(() => null);
    if (h?.status === "disabled") {
      return {
        provider: cred.provider,
        alias: cred.alias,
        ok: false,
        latency_ms: 0,
        model,
        error: "Credential is disabled.",
      };
    }
    const r = await callProvider(
      getAdapter(cred.provider),
      {
        model,
        system: "",
        messages: [{ role: "user", content: [{ type: "text", text: "Reply with OK" }] }],
        tools: [],
        maxTokens: 16,
      },
      cred.key,
      { timeoutMs: TEST_TIMEOUT_MS, fetchFn: deps.fetchFn, now: deps.clock.now, secrets },
    );

    const at = deps.clock.now();
    const cost = r.ok ? costUsd(model, r.response.usage, table) : 0;
    try {
      if (r.ok) {
        await deps.health.markSuccess(cred.provider, cred.alias);
      } else {
        const kind = classifyError(r.error);
        if (kind === "invalid_credential") {
          await deps.health.markFailure(cred.provider, cred.alias, "invalid", null, r.error.message);
        } else if (kind === "quota_exhausted") {
          const ms = r.error.cooldownMs ?? r.error.retryAfterMs ?? DEFAULT_QUOTA_COOLDOWN_MS;
          await deps.health.markFailure(
            cred.provider,
            cred.alias,
            "quota_exhausted",
            new Date(at + ms),
            r.error.message,
          );
        } else if (isLongRateLimit(r.error)) {
          const ms = r.error.retryAfterMs ?? DEFAULT_RATE_LIMIT_COOLDOWN_MS;
          await deps.health.markFailure(cred.provider, cred.alias, "rate_limited", new Date(at + ms), r.error.message);
        } else if (kind !== "bad_request") {
          await deps.health.markFailure(
            cred.provider,
            cred.alias,
            h?.status ?? "ok",
            h?.cooldown_until ? new Date(h.cooldown_until) : null,
            r.error.message,
          );
        }
      }
      await deps.usage.record({
        user_id: userId,
        request_id: `status-test-${randomId()}`,
        provider: cred.provider,
        model,
        credential_alias: cred.alias,
        input_tokens: r.ok ? r.response.usage.input_tokens : 0,
        output_tokens: r.ok ? r.response.usage.output_tokens : 0,
        cost_usd: cost,
        status: r.ok ? "ok" : "error",
        latency_ms: r.latencyMs,
      });
    } catch (e) {
      deps.log({
        event: "ai_status_bookkeeping_failed",
        provider: cred.provider,
        alias: cred.alias,
        error: redactAll(String(e), secrets),
      });
    }
    deps.log({
      event: "ai_status_test",
      provider: cred.provider,
      alias: cred.alias,
      status: r.ok ? 200 : r.error.status,
      latency_ms: r.latencyMs,
    });
    return {
      provider: cred.provider,
      alias: cred.alias,
      ok: r.ok,
      latency_ms: r.latencyMs,
      model,
      error: r.ok ? null : redactAll(r.error.message, secrets),
    };
  }));
  return jsonResponse(200, { results });
}
