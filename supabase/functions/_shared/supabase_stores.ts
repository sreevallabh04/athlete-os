// Supabase (service role) implementations of the persistence interfaces.
// All tables used here are server-only (RLS on, no client policies) except
// user_settings, which is read with the service role on the user's behalf.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.75.0";
import type { CredentialAlias } from "./credentials.ts";
import { isProviderId, type ProviderId } from "./providers/types.ts";
import type { RateLimitStore } from "./ratelimit.ts";
import type { BreakerSnapshot, BreakerStore, CredentialHealth, CredentialStatus, HealthStore } from "./resilience.ts";
import type {
  CachedResponse,
  MonthUsage,
  ResponseCache,
  UsageRow,
  UsageStore,
  UserSettings,
  UserSettingsStore,
} from "./stores.ts";

function fail(op: string, error: { message?: string } | null): never {
  // Database errors never contain provider secrets, but keep them short.
  throw new Error(`${op} failed: ${error?.message?.slice(0, 200) ?? "unknown error"}`);
}

export class SupabaseUsageStore implements UsageStore {
  constructor(private readonly db: SupabaseClient) {}

  async monthSpend(userId: string, monthStart: Date): Promise<number> {
    const { data, error } = await this.db.rpc("ai_month_spend", {
      p_user: userId,
      p_month_start: monthStart.toISOString(),
    });
    if (error) fail("ai_month_spend", error);
    return Number(data ?? 0);
  }

  async globalMonthSpend(monthStart: Date): Promise<number> {
    const { data, error } = await this.db.rpc("ai_global_month_spend", {
      p_month_start: monthStart.toISOString(),
    });
    if (error) fail("ai_global_month_spend", error);
    return Number(data ?? 0);
  }

  async monthUsage(userId: string, monthStart: Date): Promise<MonthUsage> {
    const { data, error } = await this.db.rpc("ai_month_usage", {
      p_user: userId,
      p_month_start: monthStart.toISOString(),
    });
    if (error) fail("ai_month_usage", error);
    const row = Array.isArray(data) ? data[0] : data;
    return {
      requests: Number(row?.requests ?? 0),
      input_tokens: Number(row?.input_tokens ?? 0),
      output_tokens: Number(row?.output_tokens ?? 0),
      cost_usd: Number(row?.cost_usd ?? 0),
    };
  }

  async record(row: UsageRow): Promise<void> {
    const { error } = await this.db.from("ai_usage").upsert(row, { onConflict: "request_id" });
    if (error) fail("ai_usage upsert", error);
  }
}

export class SupabaseResponseCache implements ResponseCache {
  constructor(private readonly db: SupabaseClient) {}

  async get(requestId: string): Promise<CachedResponse | null> {
    const { data, error } = await this.db
      .from("ai_response_cache")
      .select("user_id, response, created_at")
      .eq("request_id", requestId)
      .maybeSingle();
    if (error) fail("ai_response_cache select", error);
    return (data as CachedResponse | null) ?? null;
  }

  async put(requestId: string, userId: string, response: Record<string, unknown>): Promise<void> {
    const { error } = await this.db
      .from("ai_response_cache")
      .upsert({ request_id: requestId, user_id: userId, response, created_at: new Date().toISOString() }, {
        onConflict: "request_id",
      });
    if (error) fail("ai_response_cache upsert", error);
  }
}

export class SupabaseUserSettingsStore implements UserSettingsStore {
  constructor(private readonly db: SupabaseClient) {}

  async get(userId: string): Promise<UserSettings | null> {
    const { data, error } = await this.db
      .from("user_settings")
      .select("primary_provider, model, fallback_providers, max_tokens, timeout_ms, monthly_budget_usd")
      .eq("user_id", userId)
      .maybeSingle();
    if (error) fail("user_settings select", error);
    if (!data) return null;
    return {
      primary_provider: isProviderId(data.primary_provider) ? data.primary_provider : null,
      model: typeof data.model === "string" ? data.model : null,
      fallback_providers: Array.isArray(data.fallback_providers) ? data.fallback_providers.filter(isProviderId) : [],
      max_tokens: data.max_tokens ?? null,
      timeout_ms: data.timeout_ms ?? null,
      monthly_budget_usd: data.monthly_budget_usd === null || data.monthly_budget_usd === undefined
        ? null
        : Number(data.monthly_budget_usd),
    };
  }
}

export class SupabaseRateLimitStore implements RateLimitStore {
  constructor(private readonly db: SupabaseClient) {}

  async increment(userId: string, bucket: string, windowStart: Date): Promise<number> {
    const { data, error } = await this.db.rpc("increment_rate_limit", {
      p_user: userId,
      p_bucket: bucket,
      p_window_start: windowStart.toISOString(),
    });
    if (error) fail("increment_rate_limit", error);
    return Number(data);
  }
}

export class SupabaseHealthStore implements HealthStore {
  readonly #seen = new Map<string, CredentialHealth | null>();
  constructor(private readonly db: SupabaseClient) {}

  #k(p: ProviderId, a: CredentialAlias) {
    return `${p}/${a}`;
  }

  async get(provider: ProviderId, alias: CredentialAlias): Promise<CredentialHealth | null> {
    const { data, error } = await this.db
      .from("ai_credential_health")
      .select("provider, alias, status, cooldown_until, consecutive_failures, last_error")
      .eq("provider", provider)
      .eq("alias", alias)
      .maybeSingle();
    if (error) fail("ai_credential_health select", error);
    const row = (data as CredentialHealth | null) ?? null;
    this.#seen.set(this.#k(provider, alias), row);
    return row;
  }

  async list(): Promise<CredentialHealth[]> {
    const { data, error } = await this.db
      .from("ai_credential_health")
      .select("provider, alias, status, cooldown_until, consecutive_failures, last_error");
    if (error) fail("ai_credential_health list", error);
    return (data as CredentialHealth[]) ?? [];
  }

  async markSuccess(provider: ProviderId, alias: CredentialAlias): Promise<void> {
    const k = this.#k(provider, alias);
    const prev = this.#seen.get(k);
    // Skip the write when we know the row is already clean (or absent).
    if (
      this.#seen.has(k) &&
      (!prev || (prev.status === "ok" && prev.consecutive_failures === 0 && !prev.cooldown_until && !prev.last_error))
    ) {
      return;
    }
    const row = { provider, alias, status: "ok", cooldown_until: null, consecutive_failures: 0, last_error: null };
    const { error } = await this.db.from("ai_credential_health").upsert(row, { onConflict: "provider,alias" });
    if (error) fail("ai_credential_health upsert", error);
    this.#seen.set(k, row as CredentialHealth);
  }

  async markFailure(
    provider: ProviderId,
    alias: CredentialAlias,
    status: CredentialStatus,
    cooldownUntil: Date | null,
    errorText: string,
  ): Promise<void> {
    const k = this.#k(provider, alias);
    const prev = this.#seen.has(k) ? this.#seen.get(k) : await this.get(provider, alias);
    const row = {
      provider,
      alias,
      status,
      cooldown_until: cooldownUntil ? cooldownUntil.toISOString() : null,
      consecutive_failures: (prev?.consecutive_failures ?? 0) + 1,
      last_error: errorText.slice(0, 500),
    };
    const { error } = await this.db.from("ai_credential_health").upsert(row, { onConflict: "provider,alias" });
    if (error) fail("ai_credential_health upsert", error);
    this.#seen.set(k, row as CredentialHealth);
  }
}

const CLOSED: BreakerSnapshot = { state: "closed", consecutive_failures: 0, opened_at: null };

export class SupabaseBreakerStore implements BreakerStore {
  readonly #seen = new Map<ProviderId, string>();
  constructor(private readonly db: SupabaseClient) {}

  async load(provider: ProviderId): Promise<BreakerSnapshot | null> {
    const { data, error } = await this.db
      .from("ai_circuit_state")
      .select("state, consecutive_failures, opened_at")
      .eq("provider", provider)
      .maybeSingle();
    if (error) fail("ai_circuit_state select", error);
    if (!data) {
      this.#seen.set(provider, JSON.stringify(CLOSED));
      return null;
    }
    const snap: BreakerSnapshot = {
      state: data.state,
      consecutive_failures: Number(data.consecutive_failures ?? 0),
      opened_at: data.opened_at ? Date.parse(data.opened_at) : null,
    };
    this.#seen.set(provider, JSON.stringify(snap));
    return snap;
  }

  async save(provider: ProviderId, snapshot: BreakerSnapshot): Promise<void> {
    const key = JSON.stringify(snapshot);
    const prev = this.#seen.get(provider);
    if (prev === key) return;
    const { error } = await this.db.from("ai_circuit_state").upsert({
      provider,
      state: snapshot.state,
      consecutive_failures: snapshot.consecutive_failures,
      opened_at: snapshot.opened_at ? new Date(snapshot.opened_at).toISOString() : null,
    }, { onConflict: "provider" });
    if (error) fail("ai_circuit_state upsert", error);
    this.#seen.set(provider, key);
  }
}
