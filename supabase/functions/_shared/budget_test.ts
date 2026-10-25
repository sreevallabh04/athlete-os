import { assert, assertAlmostEquals, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  allowedModels,
  cheapestModel,
  checkBudget,
  costUsd,
  effectiveUserBudget,
  globalBudgetUsd,
  isModelAllowed,
  isPriceEstimated,
  loadPriceTable,
  monthStartUtc,
  providerForModel,
} from "./budget.ts";

const env = (vars: Record<string, string> = {}) => (n: string) => vars[n];

Deno.test("budget: thresholds 50/80/100", () => {
  const base = { globalSpend: 0, userBudget: 10, globalBudget: 100 };
  assertEquals(checkBudget({ ...base, userSpend: 4.99 }).alerts, []);
  const half = checkBudget({ ...base, userSpend: 5 });
  assertEquals(half.alerts, [50]);
  assertEquals(half.percent, 50);
  assert(half.allowed);
  assertEquals(checkBudget({ ...base, userSpend: 8.2 }).alerts, [50, 80]);
  const full = checkBudget({ ...base, userSpend: 10 });
  assertEquals(full.alerts, [50, 80, 100]);
  assertFalse(full.allowed);
  assert(full.reason?.includes("Your"));
});

Deno.test("budget: refusal at >= 100% of global budget", () => {
  const r = checkBudget({ userSpend: 0.5, userBudget: 10, globalSpend: 10, globalBudget: 10 });
  assertFalse(r.allowed);
  assertEquals(r.percent, 5);
  assertEquals(r.alerts, [50, 80, 100]);
  assert(r.reason?.includes("app"));
  assert(checkBudget({ userSpend: 0, userBudget: 10, globalSpend: 9.99, globalBudget: 10 }).allowed);
});

Deno.test("budget: zero budget refuses", () => {
  assertFalse(checkBudget({ userSpend: 0, userBudget: 0, globalSpend: 0, globalBudget: 10 }).allowed);
});

Deno.test("budget: effective user budget = min(pref, setting, global)", () => {
  assertEquals(effectiveUserBudget(null, null, 10), 10);
  assertEquals(effectiveUserBudget(5, null, 10), 5);
  assertEquals(effectiveUserBudget(50, 3, 10), 3);
  assertEquals(effectiveUserBudget(-1, undefined, 10), 10);
  assertEquals(globalBudgetUsd(env()), 10);
  assertEquals(globalBudgetUsd(env({ AI_MONTHLY_BUDGET_USD: "25.5" })), 25.5);
  assertEquals(globalBudgetUsd(env({ AI_MONTHLY_BUDGET_USD: "abc" })), 10);
});

Deno.test("pricing: cost per model", () => {
  assertAlmostEquals(costUsd("claude-sonnet-5-5", { input_tokens: 1_000_000, output_tokens: 1_000_000 }), 12);
  assertAlmostEquals(costUsd("gpt-5.4-mini", { input_tokens: 2_000, output_tokens: 1_000 }), 0.006);
  assertAlmostEquals(costUsd("gemini-3.8-flash", { input_tokens: 1_000_000, output_tokens: 0 }), 0.75);
  assertAlmostEquals(costUsd("claude-opus-5-5", { input_tokens: 0, output_tokens: 1_000_000 }), 20);
});

Deno.test("pricing: haiku tiered above 100K prompt tokens", () => {
  assertAlmostEquals(costUsd("claude-haiku-5-5", { input_tokens: 100_000, output_tokens: 10_000 }), 0.01 + 0.005);
  assertAlmostEquals(
    costUsd("claude-haiku-5-5", { input_tokens: 100_001, output_tokens: 10_000 }),
    0.0500005 + 0.025,
    1e-6,
  );
});

Deno.test("pricing: unknown model uses conservative fallback and is flagged", () => {
  assert(isPriceEstimated("mystery-model"));
  assertFalse(isPriceEstimated("claude-sonnet-5-5"));
  assertAlmostEquals(costUsd("mystery-model", { input_tokens: 1_000_000, output_tokens: 0 }), 15);
});

Deno.test("pricing: AI_PRICE_TABLE_JSON overrides and adds models", () => {
  const e = env({
    AI_PRICE_TABLE_JSON: JSON.stringify({
      "claude-sonnet-5-5": { in: 3, out: 15 },
      "gemini-9-pro": { in: 1, out: 2 },
      "bad": { in: "x" },
    }),
  });
  const t = loadPriceTable(e);
  assertEquals(t["claude-sonnet-5-5"].in, 3);
  assertEquals(t["claude-sonnet-5-5"].provider, "anthropic");
  assertEquals(t["gemini-9-pro"].provider, "gemini");
  assertFalse("bad" in t);
  assert(isModelAllowed("gemini", "gemini-9-pro", e));
});

Deno.test("allowlist: price-table models per provider + env extras + default", () => {
  const e = env({ AI_ALLOWED_MODELS_OPENAI: "gpt-5.4, gpt-5.4-nano", AI_DEFAULT_MODEL_GEMINI: "gemini-x" });
  assertEquals(allowedModels("anthropic", e).sort(), ["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5"]);
  assertEquals(allowedModels("openai", e).sort(), ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano"]);
  assert(allowedModels("gemini", e).includes("gemini-x"));
  assertFalse(isModelAllowed("anthropic", "gpt-5.4-mini", e));
  assertFalse(isModelAllowed("anthropic", "claude-unknown", e));
  assertEquals(providerForModel("gpt-5.4", e), "openai");
  assertEquals(providerForModel("nope", e), undefined);
});

Deno.test("cheapest model per provider", () => {
  assertEquals(cheapestModel("anthropic", env()), "claude-haiku-5-5");
  assertEquals(cheapestModel("openai", env()), "gpt-5.4-mini");
  assertEquals(cheapestModel("gemini", env()), "gemini-3.8-flash");
});

Deno.test("month start is the first day of the UTC month", () => {
  assertEquals(monthStartUtc(new Date("2026-10-25T23:59:00-05:00")).toISOString(), "2026-10-01T00:00:00.000Z");
  assertEquals(monthStartUtc(new Date("2026-11-01T00:30:00+02:00")).toISOString(), "2026-10-01T00:00:00.000Z");
});
