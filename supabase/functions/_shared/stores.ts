// Persistence interfaces used by the AI functions, plus in-memory versions for
// tests. Supabase-backed implementations live in supabase_stores.ts.
import type { ProviderId } from "./providers/types.ts";

export type UsageStatus = "ok" | "error" | "cached" | "refused";

export interface UsageRow {
  user_id: string;
  request_id: string;
  provider: ProviderId | null;
  model: string | null;
  credential_alias: string | null;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  status: UsageStatus;
  latency_ms: number | null;
}

export interface MonthUsage {
  requests: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
}

export interface UsageStore {
  monthSpend(userId: string, monthStart: Date): Promise<number>;
  globalMonthSpend(monthStart: Date): Promise<number>;
  monthUsage(userId: string, monthStart: Date): Promise<MonthUsage>;
  /**
   * Records one call keyed by request_id. A previous 'error'/'refused' row of
   * the same user is replaced (client retry); a previous 'ok' row or another
   * user's row is never overwritten — the call is stored under a new key so
   * paid usage can't be erased by re-sending an old request_id.
   */
  record(row: UsageRow): Promise<void>;
}

export interface CachedResponse {
  user_id: string;
  response: Record<string, unknown>;
  created_at: string;
}

export interface ResponseCache {
  get(requestId: string): Promise<CachedResponse | null>;
  put(requestId: string, userId: string, response: Record<string, unknown>): Promise<void>;
}

export interface UserSettings {
  primary_provider: ProviderId | null;
  model: string | null;
  fallback_providers: ProviderId[];
  max_tokens: number | null;
  timeout_ms: number | null;
  monthly_budget_usd: number | null;
}

export interface UserSettingsStore {
  get(userId: string): Promise<UserSettings | null>;
}

export const CACHE_TTL_MS = 24 * 3_600_000;

// ---------------------------------------------------------------------------
// In-memory implementations (tests / local experiments)
// ---------------------------------------------------------------------------

export class InMemoryUsageStore implements UsageStore {
  readonly rows = new Map<string, UsageRow & { created_at: number }>();
  constructor(private readonly now: () => number = Date.now) {}
  #since(monthStart: Date) {
    return [...this.rows.values()].filter((r) => r.created_at >= monthStart.getTime());
  }
  monthSpend(userId: string, monthStart: Date): Promise<number> {
    return Promise.resolve(
      this.#since(monthStart).filter((r) => r.user_id === userId).reduce((s, r) => s + r.cost_usd, 0),
    );
  }
  globalMonthSpend(monthStart: Date): Promise<number> {
    return Promise.resolve(this.#since(monthStart).reduce((s, r) => s + r.cost_usd, 0));
  }
  monthUsage(userId: string, monthStart: Date): Promise<MonthUsage> {
    const rows = this.#since(monthStart).filter((r) => r.user_id === userId && r.status !== "refused");
    return Promise.resolve({
      requests: rows.length,
      input_tokens: rows.reduce((s, r) => s + r.input_tokens, 0),
      output_tokens: rows.reduce((s, r) => s + r.output_tokens, 0),
      cost_usd: rows.reduce((s, r) => s + r.cost_usd, 0),
    });
  }
  /** Mirrors record_ai_usage() in SQL. */
  record(row: UsageRow): Promise<void> {
    const prev = this.rows.get(row.request_id);
    const key = !prev || (prev.user_id === row.user_id && prev.status !== "ok")
      ? row.request_id
      : `${row.request_id}:${crypto.randomUUID().replaceAll("-", "")}`;
    this.rows.set(key, { ...row, request_id: key, created_at: this.now() });
    return Promise.resolve();
  }
}

export class InMemoryResponseCache implements ResponseCache {
  readonly data = new Map<string, CachedResponse>();
  constructor(private readonly now: () => number = Date.now) {}
  get(requestId: string): Promise<CachedResponse | null> {
    return Promise.resolve(this.data.get(requestId) ?? null);
  }
  put(requestId: string, userId: string, response: Record<string, unknown>): Promise<void> {
    this.data.set(requestId, { user_id: userId, response, created_at: new Date(this.now()).toISOString() });
    return Promise.resolve();
  }
}

export class InMemoryUserSettingsStore implements UserSettingsStore {
  readonly data = new Map<string, UserSettings>();
  get(userId: string): Promise<UserSettings | null> {
    return Promise.resolve(this.data.get(userId) ?? null);
  }
}
