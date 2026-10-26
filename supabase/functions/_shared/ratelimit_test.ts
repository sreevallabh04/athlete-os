import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { checkRateLimit, InMemoryRateLimitStore, limitFromEnv, rateLimitPerMin } from "./ratelimit.ts";

Deno.test("rate limit: fixed window per user and bucket", async () => {
  const store = new InMemoryRateLimitStore();
  const t0 = Date.UTC(2026, 9, 25, 12, 0, 15); // 15 s into the minute
  for (let i = 0; i < 3; i++) assert((await checkRateLimit(store, "u1", "ai-chat", 3, t0)).allowed);
  const denied = await checkRateLimit(store, "u1", "ai-chat", 3, t0);
  assertFalse(denied.allowed);
  assertEquals(denied.retryAfterS, 45);
  // other user / bucket unaffected
  assert((await checkRateLimit(store, "u2", "ai-chat", 3, t0)).allowed);
  assert((await checkRateLimit(store, "u1", "ai-status-test", 3, t0)).allowed);
  // next window resets
  assert((await checkRateLimit(store, "u1", "ai-chat", 3, t0 + 45_000)).allowed);
});

Deno.test("rate limit: env override", () => {
  assertEquals(rateLimitPerMin(() => undefined), 30);
  assertEquals(rateLimitPerMin((n) => (n === "AI_RATE_LIMIT_PER_MIN" ? "12" : undefined)), 12);
  assertEquals(rateLimitPerMin(() => "-3"), 30);
});

Deno.test("rate limit: limitFromEnv falls back on missing / invalid values", () => {
  const env = (v: string | undefined) => (n: string) => (n === "X_PER_MIN" ? v : undefined);
  assertEquals(limitFromEnv(env(undefined), "X_PER_MIN", 10), 10);
  assertEquals(limitFromEnv(env("25"), "X_PER_MIN", 10), 25);
  assertEquals(limitFromEnv(env("0"), "X_PER_MIN", 10), 10);
  assertEquals(limitFromEnv(env("2.5"), "X_PER_MIN", 10), 10);
  assertEquals(limitFromEnv(env("abc"), "X_PER_MIN", 10), 10);
});
