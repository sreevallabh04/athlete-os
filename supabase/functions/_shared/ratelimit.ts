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

export function rateLimitPerMin(env: EnvFn): number {
  const v = Number(env("AI_RATE_LIMIT_PER_MIN"));
  return Number.isInteger(v) && v > 0 ? v : DEFAULT_RATE_LIMIT_PER_MIN;
}

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
