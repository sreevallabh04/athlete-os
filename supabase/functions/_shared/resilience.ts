// Retry, credential rotation, circuit breaking and provider fallback.
//
// Policy summary
// * Transient errors (5xx, 529 overloaded, timeouts, network) and short rate
//   limits (Retry-After <= 20 s) are retried on the SAME credential with
//   full-jitter exponential backoff (max 3 attempts, bounded by a deadline).
// * A credential is never rotated because of a transient failure. When the
//   retries for a call are exhausted the failure counts toward the provider's
//   circuit breaker and we fall back to the NEXT PROVIDER.
// * invalid_credential -> credential marked `invalid` (persisted), try the
//   next credential of the same provider.
// * quota_exhausted / long Retry-After -> credential gets cooldown_until
//   (quota: Retry-After / reset hint / 1 h; rate limit: Retry-After / 60 s),
//   try the next credential of the same provider.
// * request_too_large -> (e.g. Groq free-tier TPM smaller than the request)
//   no retry, no key/breaker penalty; try the next provider.
// * bad_request -> stop immediately, no rotation, no fallback.
// * Provider fallback happens only when the current provider has no healthy
//   credential left or its circuit is open.
import type { Credential, CredentialAlias } from "./credentials.ts";
import type { CallResult } from "./providers/call.ts";
import type { ErrorKind, ParsedResponse, ProviderErrorInfo, ProviderId } from "./providers/types.ts";

// ---------------------------------------------------------------------------
// Classification & backoff
// ---------------------------------------------------------------------------

export const SHORT_RETRY_AFTER_MAX_MS = 20_000;
export const DEFAULT_QUOTA_COOLDOWN_MS = 3_600_000;
export const DEFAULT_RATE_LIMIT_COOLDOWN_MS = 60_000;
export const DEFAULT_DEADLINE_MS = 45_000;
export const MAX_ATTEMPTS_PER_CREDENTIAL = 3;
/**
 * Time kept back for the next provider while a non-last provider is tried, so
 * a hanging primary (e.g. an overloaded model that never answers) cannot eat
 * the whole deadline. Capped at a third of the total deadline.
 */
export const DEFAULT_FALLBACK_RESERVE_MS = 15_000;
const UNAVAILABLE_MSG = "All AI providers are temporarily unavailable. Please try again later.";

export function classifyError(info: ProviderErrorInfo): ErrorKind {
  if (info.kind) return info.kind;
  const s = info.status;
  if (s === 0 || s === 408 || s === 409 || s === 425 || s === 529 || s >= 500) return "transient";
  if (s === 429) return "rate_limited";
  if (s === 401 || s === 403) return "invalid_credential";
  if (s === 402) return "quota_exhausted";
  return "bad_request";
}

export function isLongRateLimit(info: ProviderErrorInfo): boolean {
  return classifyError(info) === "rate_limited" && (info.retryAfterMs ?? 0) > SHORT_RETRY_AFTER_MAX_MS;
}

export interface BackoffOptions {
  baseMs?: number;
  capMs?: number;
  retryAfterMs?: number;
  /** Time left before the overall deadline; the delay never exceeds it. */
  remainingMs?: number;
  random?: () => number;
}

/** Full jitter: random() * min(cap, base * 2^attempt); Retry-After is a floor. */
export function backoffDelayMs(attempt: number, opts: BackoffOptions = {}): number {
  const base = opts.baseMs ?? 500;
  const cap = opts.capMs ?? 8000;
  const random = opts.random ?? Math.random;
  const ceiling = Math.min(cap, base * 2 ** Math.max(0, attempt));
  let delay = random() * ceiling;
  if (opts.retryAfterMs !== undefined && opts.retryAfterMs >= 0) delay = Math.max(opts.retryAfterMs, delay);
  if (opts.remainingMs !== undefined) delay = Math.min(delay, Math.max(0, opts.remainingMs));
  return Math.floor(delay);
}

// ---------------------------------------------------------------------------
// withRetry (single credential)
// ---------------------------------------------------------------------------

export interface Clock {
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  random: () => number;
}

export const realClock: Clock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  random: Math.random,
};

export type AttemptResult<T> = { ok: true; value: T } | { ok: false; error: ProviderErrorInfo };

export type RetryOutcome<T> =
  | { ok: true; value: T; attempts: number }
  | { ok: false; error: ProviderErrorInfo; kind: ErrorKind; attempts: number; deadlineExceeded: boolean };

export interface RetryOptions {
  maxAttempts: number;
  deadlineAt: number;
  clock: Clock;
  baseMs?: number;
  capMs?: number;
}

export async function withRetry<T>(
  provider: ProviderId,
  fn: (attempt: number, remainingMs: number) => Promise<AttemptResult<T>>,
  opts: RetryOptions,
): Promise<RetryOutcome<T>> {
  const max = Math.max(1, Math.min(MAX_ATTEMPTS_PER_CREDENTIAL, Math.floor(opts.maxAttempts)));
  let attempts = 0;
  let lastError: ProviderErrorInfo | undefined;
  for (let attempt = 0; attempt < max; attempt++) {
    const remaining = opts.deadlineAt - opts.clock.now();
    if (remaining <= 0) break;
    attempts++;
    const r = await fn(attempt, remaining);
    if (r.ok) return { ok: true, value: r.value, attempts };
    lastError = r.error;
    const kind = classifyError(r.error);
    const retryable = kind === "transient" || (kind === "rate_limited" && !isLongRateLimit(r.error));
    if (!retryable || attempt === max - 1) {
      return { ok: false, error: r.error, kind, attempts, deadlineExceeded: false };
    }
    const left = opts.deadlineAt - opts.clock.now();
    if (r.error.retryAfterMs !== undefined && r.error.retryAfterMs >= left) {
      // Cannot honour Retry-After within the deadline.
      return { ok: false, error: r.error, kind, attempts, deadlineExceeded: false };
    }
    const delay = backoffDelayMs(attempt, {
      baseMs: opts.baseMs,
      capMs: opts.capMs,
      retryAfterMs: r.error.retryAfterMs,
      remainingMs: left,
      random: opts.clock.random,
    });
    if (delay >= left) break;
    await opts.clock.sleep(delay);
  }
  const error = lastError ?? {
    provider,
    status: 0,
    kind: "transient" as const,
    code: "timeout",
    message: "Deadline exceeded before the provider could be called",
  };
  return {
    ok: false,
    error,
    kind: classifyError(error),
    attempts,
    deadlineExceeded: true,
  };
}

// ---------------------------------------------------------------------------
// Circuit breaker
// ---------------------------------------------------------------------------

export type CircuitState = "closed" | "open" | "half_open";

export interface BreakerSnapshot {
  state: CircuitState;
  consecutive_failures: number;
  /** epoch ms when the circuit (re)opened. */
  opened_at: number | null;
}

export interface BreakerOptions {
  threshold?: number;
  cooldownMs?: number;
  now?: () => number;
}

export class CircuitBreaker {
  #state: CircuitState = "closed";
  #failures = 0;
  #openedAt: number | null = null;
  #trialInFlight = false;
  readonly threshold: number;
  readonly cooldownMs: number;
  readonly #now: () => number;

  constructor(opts: BreakerOptions = {}, snapshot?: BreakerSnapshot | null) {
    this.threshold = opts.threshold ?? 5;
    this.cooldownMs = opts.cooldownMs ?? 60_000;
    this.#now = opts.now ?? Date.now;
    if (snapshot) {
      this.#state = snapshot.state === "half_open" ? "open" : snapshot.state;
      this.#failures = snapshot.consecutive_failures;
      this.#openedAt = snapshot.opened_at;
      if (this.#state === "open" && this.#openedAt === null) this.#openedAt = this.#now();
    }
  }

  get state(): CircuitState {
    if (this.#state === "open" && this.#openedAt !== null && this.#now() - this.#openedAt >= this.cooldownMs) {
      this.#state = "half_open";
      this.#trialInFlight = false;
    }
    return this.#state;
  }

  /** ms until the circuit allows a trial request (0 when it already does). */
  retryInMs(): number {
    if (this.state !== "open" || this.#openedAt === null) return 0;
    return Math.max(0, this.#openedAt + this.cooldownMs - this.#now());
  }

  /** Closed: always. Open: never. Half-open: exactly one trial request. */
  canRequest(): boolean {
    const s = this.state;
    if (s === "closed") return true;
    if (s === "open") return false;
    if (this.#trialInFlight) return false;
    this.#trialInFlight = true;
    return true;
  }

  recordSuccess(): void {
    this.#state = "closed";
    this.#failures = 0;
    this.#openedAt = null;
    this.#trialInFlight = false;
  }

  recordFailure(): void {
    const s = this.state;
    this.#failures++;
    this.#trialInFlight = false;
    if (s === "half_open" || this.#failures >= this.threshold) {
      this.#state = "open";
      this.#openedAt = this.#now();
    }
  }

  snapshot(): BreakerSnapshot {
    return { state: this.state, consecutive_failures: this.#failures, opened_at: this.#openedAt };
  }
}

export interface BreakerStore {
  load(provider: ProviderId): Promise<BreakerSnapshot | null>;
  save(provider: ProviderId, snapshot: BreakerSnapshot): Promise<void>;
}

export class InMemoryBreakerStore implements BreakerStore {
  readonly data = new Map<ProviderId, BreakerSnapshot>();
  load(provider: ProviderId): Promise<BreakerSnapshot | null> {
    return Promise.resolve(this.data.get(provider) ?? null);
  }
  save(provider: ProviderId, snapshot: BreakerSnapshot): Promise<void> {
    this.data.set(provider, { ...snapshot });
    return Promise.resolve();
  }
}

/** Lazily loads per-provider breakers from a store and persists changes. */
export class BreakerRegistry {
  readonly #breakers = new Map<ProviderId, CircuitBreaker>();
  constructor(readonly store: BreakerStore | null = null, readonly opts: BreakerOptions = {}) {}

  async get(provider: ProviderId): Promise<CircuitBreaker> {
    let b = this.#breakers.get(provider);
    if (!b) {
      let snap: BreakerSnapshot | null = null;
      try {
        snap = this.store ? await this.store.load(provider) : null;
      } catch {
        snap = null; // breaker state is advisory; never fail a request on it.
      }
      b = new CircuitBreaker(this.opts, snap);
      this.#breakers.set(provider, b);
    }
    return b;
  }

  async persist(provider: ProviderId): Promise<void> {
    const b = this.#breakers.get(provider);
    if (!b || !this.store) return;
    try {
      await this.store.save(provider, b.snapshot());
    } catch {
      // advisory only
    }
  }
}

// ---------------------------------------------------------------------------
// Credential health
// ---------------------------------------------------------------------------

export type CredentialStatus = "ok" | "rate_limited" | "quota_exhausted" | "invalid" | "disabled";

export interface CredentialHealth {
  provider: ProviderId;
  alias: CredentialAlias;
  status: CredentialStatus;
  cooldown_until: string | null;
  consecutive_failures: number;
  last_error: string | null;
}

export interface HealthStore {
  get(provider: ProviderId, alias: CredentialAlias): Promise<CredentialHealth | null>;
  list(): Promise<CredentialHealth[]>;
  markSuccess(provider: ProviderId, alias: CredentialAlias): Promise<void>;
  markFailure(
    provider: ProviderId,
    alias: CredentialAlias,
    status: CredentialStatus,
    cooldownUntil: Date | null,
    error: string,
  ): Promise<void>;
}

export class InMemoryHealthStore implements HealthStore {
  readonly data = new Map<string, CredentialHealth>();
  #k(p: ProviderId, a: CredentialAlias) {
    return `${p}/${a}`;
  }
  get(provider: ProviderId, alias: CredentialAlias): Promise<CredentialHealth | null> {
    const h = this.data.get(this.#k(provider, alias));
    return Promise.resolve(h ? { ...h } : null);
  }
  list(): Promise<CredentialHealth[]> {
    return Promise.resolve([...this.data.values()].map((h) => ({ ...h })));
  }
  markSuccess(provider: ProviderId, alias: CredentialAlias): Promise<void> {
    this.data.set(this.#k(provider, alias), {
      provider,
      alias,
      status: "ok",
      cooldown_until: null,
      consecutive_failures: 0,
      last_error: null,
    });
    return Promise.resolve();
  }
  markFailure(
    provider: ProviderId,
    alias: CredentialAlias,
    status: CredentialStatus,
    cooldownUntil: Date | null,
    error: string,
  ): Promise<void> {
    const prev = this.data.get(this.#k(provider, alias));
    this.data.set(this.#k(provider, alias), {
      provider,
      alias,
      status,
      cooldown_until: cooldownUntil ? cooldownUntil.toISOString() : null,
      consecutive_failures: (prev?.consecutive_failures ?? 0) + 1,
      last_error: error,
    });
    return Promise.resolve();
  }
}

/** True when the credential may be used now. */
export function isCredentialAvailable(h: CredentialHealth | null, nowMs: number): boolean {
  if (!h) return true;
  if (h.status === "invalid" || h.status === "disabled") return false;
  if (h.cooldown_until && Date.parse(h.cooldown_until) > nowMs) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Fallback orchestration
// ---------------------------------------------------------------------------

export interface ProviderPlan {
  provider: ProviderId;
  model: string;
}

export interface FallbackOptions {
  plan: ProviderPlan[];
  credentials: Credential[];
  health: HealthStore;
  breakers: BreakerRegistry;
  /** 1..3 attempts per credential. */
  attemptsPerCredential: number;
  deadlineAt: number;
  clock: Clock;
  invoke: (plan: ProviderPlan, credential: Credential, timeoutMs: number) => Promise<CallResult>;
  log?: (event: Record<string, unknown>) => void;
  backoffBaseMs?: number;
  backoffCapMs?: number;
  /** See DEFAULT_FALLBACK_RESERVE_MS. */
  fallbackReserveMs?: number;
}

export type FallbackFailureCode =
  | "no_provider_configured"
  | "providers_unavailable"
  | "upstream_error"
  | "timeout"
  | "invalid_request";

export type FallbackResult =
  | {
    ok: true;
    response: ParsedResponse;
    provider: ProviderId;
    model: string;
    alias: CredentialAlias;
    attempts: number;
    fallbackUsed: boolean;
    latencyMs: number;
  }
  | {
    ok: false;
    code: FallbackFailureCode;
    message: string;
    retryAfterS?: number;
    attempts: number;
    lastError?: ProviderErrorInfo;
    provider?: ProviderId;
    model?: string;
    alias?: CredentialAlias;
  };

export async function runWithFallback(opts: FallbackOptions): Promise<FallbackResult> {
  const { clock, health, breakers } = opts;
  const log = opts.log ?? (() => {});
  const configured = opts.plan.filter((p) => opts.credentials.some((c) => c.provider === p.provider));
  if (configured.length === 0) {
    return {
      ok: false,
      code: "no_provider_configured",
      message: "No AI provider is configured on the server.",
      attempts: 0,
    };
  }

  let attempts = 0;
  let minWaitMs: number | undefined;
  const noteWait = (ms: number | undefined) => {
    if (ms === undefined || ms <= 0) return;
    minWaitMs = minWaitMs === undefined ? ms : Math.min(minWaitMs, ms);
  };
  let lastFailure: Extract<FallbackResult, { ok: false }> | undefined;
  const firstProvider = configured[0].provider;
  const reserveMs = Math.max(
    0,
    Math.min(
      opts.fallbackReserveMs ?? DEFAULT_FALLBACK_RESERVE_MS,
      Math.floor((opts.deadlineAt - clock.now()) / 3),
    ),
  );

  for (const [index, plan] of configured.entries()) {
    // Non-last providers must leave time for the fallback.
    const providerDeadline = index < configured.length - 1 ? opts.deadlineAt - reserveMs : opts.deadlineAt;
    const breaker = await breakers.get(plan.provider);
    if (!breaker.canRequest()) {
      noteWait(breaker.retryInMs());
      log({ event: "circuit_open", provider: plan.provider });
      continue;
    }
    const creds = opts.credentials.filter((c) => c.provider === plan.provider);
    for (const cred of creds) {
      const now = clock.now();
      let h: CredentialHealth | null = null;
      try {
        h = await health.get(cred.provider, cred.alias);
      } catch {
        h = null;
      }
      if (!isCredentialAvailable(h, now)) {
        if (h?.cooldown_until) noteWait(Date.parse(h.cooldown_until) - now);
        continue;
      }
      if (now >= opts.deadlineAt) {
        return {
          ok: false,
          code: "timeout",
          message: "The AI request timed out.",
          attempts,
          lastError: lastFailure?.lastError,
        };
      }
      if (now >= providerDeadline) break; // this provider's share is used up; fall back
      const outcome = await withRetry<{ response: ParsedResponse; latencyMs: number }>(
        cred.provider,
        async (_attempt, remainingMs) => {
          const r = await opts.invoke(plan, cred, remainingMs);
          log({
            event: "provider_call",
            provider: cred.provider,
            alias: cred.alias,
            status: r.ok ? 200 : r.error.status,
            latency_ms: r.latencyMs,
          });
          return r.ok ? { ok: true, value: { response: r.response, latencyMs: r.latencyMs } } : r;
        },
        {
          maxAttempts: opts.attemptsPerCredential,
          deadlineAt: providerDeadline,
          clock,
          baseMs: opts.backoffBaseMs,
          capMs: opts.backoffCapMs,
        },
      );
      attempts += outcome.attempts;

      if (outcome.ok) {
        await safe(() => health.markSuccess(cred.provider, cred.alias));
        breaker.recordSuccess();
        await breakers.persist(plan.provider);
        return {
          ok: true,
          response: outcome.value.response,
          provider: plan.provider,
          model: plan.model,
          alias: cred.alias,
          attempts,
          fallbackUsed: plan.provider !== firstProvider,
          latencyMs: outcome.value.latencyMs,
        };
      }

      const err = outcome.error;
      const at = clock.now();
      const failure = {
        ok: false as const,
        attempts,
        lastError: err,
        provider: plan.provider,
        model: plan.model,
        alias: cred.alias,
      };
      log({
        event: "provider_failure",
        provider: cred.provider,
        alias: cred.alias,
        kind: outcome.kind,
        status: err.status,
        code: err.code && SAFE_CODE_RE.test(err.code) ? err.code : undefined,
      });

      if (outcome.kind === "bad_request") {
        return {
          ...failure,
          code: "invalid_request",
          message: `The AI provider rejected the request (${providerErrorSummary(err)}).`,
        };
      }
      if (outcome.kind === "request_too_large") {
        // The key and provider are healthy; this request just doesn't fit.
        lastFailure = {
          ...failure,
          code: "upstream_error",
          message: `The request is too large for ${plan.provider} (${providerErrorSummary(err)}).`,
        };
        break; // next provider
      }
      if (outcome.kind === "invalid_credential") {
        await safe(() => health.markFailure(cred.provider, cred.alias, "invalid", null, err.message));
        lastFailure = { ...failure, code: "providers_unavailable", message: UNAVAILABLE_MSG };
        continue; // next credential, same provider
      }
      if (outcome.kind === "quota_exhausted") {
        const ms = err.cooldownMs ?? err.retryAfterMs ?? DEFAULT_QUOTA_COOLDOWN_MS;
        await safe(() =>
          health.markFailure(cred.provider, cred.alias, "quota_exhausted", new Date(at + ms), err.message)
        );
        noteWait(ms);
        lastFailure = { ...failure, code: "providers_unavailable", message: UNAVAILABLE_MSG };
        continue;
      }
      if (outcome.kind === "rate_limited" && isLongRateLimit(err)) {
        const ms = err.retryAfterMs ?? DEFAULT_RATE_LIMIT_COOLDOWN_MS;
        await safe(() => health.markFailure(cred.provider, cred.alias, "rate_limited", new Date(at + ms), err.message));
        noteWait(ms);
        lastFailure = { ...failure, code: "providers_unavailable", message: UNAVAILABLE_MSG };
        continue;
      }

      // Transient (or short rate limit) with retries exhausted: do NOT rotate
      // the credential; count toward the breaker and move to the next provider.
      await safe(() => health.markFailure(cred.provider, cred.alias, "ok", null, err.message));
      breaker.recordFailure();
      await breakers.persist(plan.provider);
      noteWait(err.retryAfterMs);
      const timedOut = outcome.deadlineExceeded || err.code === "timeout";
      lastFailure = {
        ...failure,
        code: timedOut ? "timeout" : "upstream_error",
        message: timedOut ? "The AI request timed out." : "The AI provider returned an error. Please try again.",
      };
      if (clock.now() >= opts.deadlineAt) {
        return { ...lastFailure, code: "timeout", message: "The AI request timed out." };
      }
      break;
    }
  }

  const retryAfterS = minWaitMs !== undefined ? Math.max(1, Math.ceil(minWaitMs / 1000)) : undefined;
  if (lastFailure) {
    return {
      ...lastFailure,
      attempts,
      retryAfterS: lastFailure.code === "providers_unavailable" || lastFailure.code === "upstream_error"
        ? retryAfterS
        : undefined,
    };
  }
  return {
    ok: false,
    code: "providers_unavailable",
    message: "All AI providers are temporarily unavailable. Please try again later.",
    retryAfterS,
    attempts,
  };
}

const SAFE_CODE_RE = /^[A-Za-z0-9_.\-]{1,64}$/;

/**
 * Client-facing description of a provider error: provider, HTTP status and the
 * provider's short error code only. The provider's free-text message (which may
 * be a raw non-JSON body, echo request content, or carry account details) is
 * never returned to the caller; the provider_failure log carries status + code.
 */
export function providerErrorSummary(err: ProviderErrorInfo): string {
  const code = err.code && SAFE_CODE_RE.test(err.code) ? `, ${err.code}` : "";
  return `${err.provider} HTTP ${err.status}${code}`;
}

async function safe(fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
  } catch {
    // Health bookkeeping must never fail the user request.
  }
}
