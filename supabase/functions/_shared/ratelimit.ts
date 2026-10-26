// Fixed-window per-user rate limiting backed by the increment_rate_limit RPC.
import type { EnvFn } from "./providers/types.ts";

export interface RateLimitStore {
  /** Atomically increments and returns the counter for the window. */
  increment(userId: string, bucket: string, windowStart: Date): Promise<number>;
}

export class InMemoryRateLimitStore implements RateLimitStore {
  readonly counts = new Map<string, number>();
  increment(userId: string, bucket: string, windowStart: Date): Promise<number> {
    const k = `${userId}|${bucket}|${windowStart.toISOString()}`;
    const n = (this.counts.get(k) ?? 0) + 1;
    this.counts.set(k, n);
    return Promise.resolve(n);
  }
}

export interface RateLimitResult {
  allowed: boolean;
  retryAfterS: number;
  count: number;
  limit: number;
}

export const DEFAULT_RATE_LIMIT_PER_MIN = 30;

/** A positive integer limit from [name], else [fallback]. */
export function limitFromEnv(env: EnvFn, name: string, fallback: number): number {
  const v = Number(env(name));
  return Number.isInteger(v) && v > 0 ? v : fallback;
}

export function rateLimitPerMin(env: EnvFn): number {
  return limitFromEnv(env, "AI_RATE_LIMIT_PER_MIN", DEFAULT_RATE_LIMIT_PER_MIN);
}

/**
 * Pseudo user id for process-wide counters kept in an [InMemoryRateLimitStore]
 * (never sent to the database: api_rate_limits.user_id references auth.users).
 */
export const GLOBAL_RATE_LIMIT_KEY = "*";

export async function checkRateLimit(
  store: RateLimitStore,
  userId: string,
  bucket: string,
  limit: number,
  nowMs: number = Date.now(),
  windowMs = 60_000,
): Promise<RateLimitResult> {
  const start = Math.floor(nowMs / windowMs) * windowMs;
  const count = await store.increment(userId, bucket, new Date(start));
  const retryAfterS = Math.max(1, Math.ceil((start + windowMs - nowMs) / 1000));
  return { allowed: count <= limit, retryAfterS: count <= limit ? 0 : retryAfterS, count, limit };
}
