// Model allowlists, pricing and monthly budget enforcement.
import { defaultModel } from "./credentials.ts";
import { type EnvFn, isProviderId, PROVIDER_IDS, type ProviderId, type Usage } from "./providers/types.ts";
import { isPlainObject } from "./providers/util.ts";

export interface PriceTier {
  /** Applies when the prompt has MORE than this many input tokens. */
  above_input_tokens: number;
  in: number;
  out: number;
}

/** USD per 1M tokens. */
export interface ModelPrice {
  provider: ProviderId;
  in: number;
  out: number;
  tiers?: PriceTier[];
}

export type PriceTable = Record<string, ModelPrice>;

export const DEFAULT_PRICES: PriceTable = {
  "claude-sonnet-5-5": { provider: "anthropic", in: 2, out: 10 },
  "claude-haiku-5-5": {
    provider: "anthropic",
    in: 0.10,
    out: 0.50,
    tiers: [{ above_input_tokens: 100_000, in: 0.50, out: 2.50 }],
  },
  "claude-opus-5-5": { provider: "anthropic", in: 4, out: 20 },
  "gpt-5.4-mini": { provider: "openai", in: 0.75, out: 4.50 },
  "gemini-3.8-flash": { provider: "gemini", in: 0.75, out: 3.75 },
};

/** Conservative price for allowlisted models without a known price. */
export const FALLBACK_PRICE: Omit<ModelPrice, "provider"> = { in: 15, out: 75 };

export const BUDGET_THRESHOLDS = [50, 80, 100] as const;
export const DEFAULT_GLOBAL_BUDGET_USD = 10;

export function inferProvider(model: string): ProviderId | undefined {
  const m = model.toLowerCase();
  if (m.startsWith("claude")) return "anthropic";
  if (m.startsWith("gemini")) return "gemini";
  if (m.startsWith("gpt") || /^o\d/.test(m)) return "openai";
  return undefined;
}

/** Default table merged with AI_PRICE_TABLE_JSON ({model: {in, out, provider?, tiers?}}). */
export function loadPriceTable(env: EnvFn): PriceTable {
  const table: PriceTable = { ...DEFAULT_PRICES };
  const raw = env("AI_PRICE_TABLE_JSON");
  if (!raw) return table;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return table;
  }
  if (!isPlainObject(parsed)) return table;
  for (const [model, v] of Object.entries(parsed)) {
    if (!isPlainObject(v)) continue;
    const inP = Number(v.in);
    const outP = Number(v.out);
    if (!Number.isFinite(inP) || !Number.isFinite(outP) || inP < 0 || outP < 0) continue;
    const provider = isProviderId(v.provider) ? v.provider : table[model]?.provider ?? inferProvider(model);
    if (!provider) continue;
    const tiers = Array.isArray(v.tiers)
      ? v.tiers.filter(isPlainObject).map((t) => ({
        above_input_tokens: Number(t.above_input_tokens),
        in: Number(t.in),
        out: Number(t.out),
      })).filter((t) => [t.above_input_tokens, t.in, t.out].every((n) => Number.isFinite(n) && n >= 0))
      : undefined;
    table[model] = { provider, in: inP, out: outP, ...(tiers && tiers.length ? { tiers } : {}) };
  }
  return table;
}

const ALLOW_ENV: Record<ProviderId, string> = {
  anthropic: "AI_ALLOWED_MODELS_ANTHROPIC",
  openai: "AI_ALLOWED_MODELS_OPENAI",
  gemini: "AI_ALLOWED_MODELS_GEMINI",
};

/** Priced models of the provider + AI_ALLOWED_MODELS_<PROVIDER> + the provider default. */
export function allowedModels(provider: ProviderId, env: EnvFn, table: PriceTable = loadPriceTable(env)): string[] {
  const set = new Set<string>();
  for (const [model, p] of Object.entries(table)) if (p.provider === provider) set.add(model);
  for (const m of (env(ALLOW_ENV[provider]) ?? "").split(",")) {
    const t = m.trim();
    if (t) set.add(t);
  }
  set.add(defaultModel(provider, env));
  return [...set];
}

export function isModelAllowed(provider: ProviderId, model: string, env: EnvFn, table?: PriceTable): boolean {
  return allowedModels(provider, env, table).includes(model);
}

/** Which provider's allowlist contains this model (first match in canonical order). */
export function providerForModel(model: string, env: EnvFn, table?: PriceTable): ProviderId | undefined {
  return PROVIDER_IDS.find((p) => isModelAllowed(p, model, env, table));
}

export function priceFor(
  model: string,
  table: PriceTable = DEFAULT_PRICES,
): { price: Omit<ModelPrice, "provider">; estimated: boolean } {
  const p = table[model];
  return p ? { price: p, estimated: false } : { price: FALLBACK_PRICE, estimated: true };
}

export function isPriceEstimated(model: string, table: PriceTable = DEFAULT_PRICES): boolean {
  return priceFor(model, table).estimated;
}

/** USD cost of one call (6 dp). Tiered prices apply to the whole request. */
export function costUsd(model: string, usage: Usage, table: PriceTable = DEFAULT_PRICES): number {
  const { price } = priceFor(model, table);
  let inP = price.in;
  let outP = price.out;
  const tiers = [...(price.tiers ?? [])].sort((a, b) => a.above_input_tokens - b.above_input_tokens);
  for (const t of tiers) {
    if (usage.input_tokens > t.above_input_tokens) {
      inP = t.in;
      outP = t.out;
    }
  }
  const cost = (usage.input_tokens * inP + usage.output_tokens * outP) / 1_000_000;
  return Math.round(cost * 1e6) / 1e6;
}

/** Cheapest allowlisted model (by in+out price) — used for credential tests. */
export function cheapestModel(provider: ProviderId, env: EnvFn, table: PriceTable = loadPriceTable(env)): string {
  let best: string | undefined;
  let bestPrice = Infinity;
  for (const m of allowedModels(provider, env, table)) {
    const { price, estimated } = priceFor(m, table);
    if (estimated) continue;
    const p = price.in + price.out;
    if (p < bestPrice) {
      best = m;
      bestPrice = p;
    }
  }
  return best ?? defaultModel(provider, env);
}

export function monthStartUtc(now: Date = new Date()): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

export function globalBudgetUsd(env: EnvFn): number {
  const v = Number(env("AI_MONTHLY_BUDGET_USD"));
  return Number.isFinite(v) && v >= 0 && env("AI_MONTHLY_BUDGET_USD")?.trim() ? v : DEFAULT_GLOBAL_BUDGET_USD;
}

/** min(request preference, user_settings value, global budget). */
export function effectiveUserBudget(
  requestPref: number | null | undefined,
  userSetting: number | null | undefined,
  globalBudget: number,
): number {
  let b = globalBudget;
  for (const v of [requestPref, userSetting]) {
    if (typeof v === "number" && Number.isFinite(v) && v >= 0) b = Math.min(b, v);
  }
  return b;
}

export interface BudgetInput {
  userSpend: number;
  globalSpend: number;
  userBudget: number;
  globalBudget: number;
}

export interface BudgetCheck {
  allowed: boolean;
  /** User spend as % of the effective user budget (2 dp). */
  percent: number;
  /** Thresholds (50/80/100) reached by user OR global spend. */
  alerts: number[];
  reason?: string;
}

function pct(spend: number, budget: number): number {
  if (budget <= 0) return 100; // a zero budget disables AI
  return (spend / budget) * 100;
}

export function checkBudget(i: BudgetInput): BudgetCheck {
  const userPct = pct(i.userSpend, i.userBudget);
  const globalPct = pct(i.globalSpend, i.globalBudget);
  const worst = Math.max(userPct, globalPct);
  const alerts = BUDGET_THRESHOLDS.filter((t) => worst >= t);
  const percent = Math.round(Math.min(userPct, 999_999) * 100) / 100;
  if (userPct >= 100) {
    return { allowed: false, percent, alerts, reason: "Your monthly AI budget has been reached." };
  }
  if (globalPct >= 100) {
    return { allowed: false, percent, alerts, reason: "The monthly AI budget for this app has been reached." };
  }
  return { allowed: true, percent, alerts };
}
