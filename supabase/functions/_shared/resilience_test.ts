import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  backoffDelayMs,
  BreakerRegistry,
  CircuitBreaker,
  type Clock,
  InMemoryBreakerStore,
  InMemoryHealthStore,
  isCredentialAvailable,
  type ProviderPlan,
  runWithFallback,
  withRetry,
} from "./resilience.ts";
import { Credential } from "./credentials.ts";
import type { CallResult } from "./providers/call.ts";
import type { ProviderErrorInfo, ProviderId } from "./providers/types.ts";

function fakeClock(start = 1_000_000, random = 0.5): Clock & { sleeps: number[]; t: number } {
  const c = {
    t: start,
    sleeps: [] as number[],
    now: () => c.t,
    sleep: (ms: number) => {
      c.sleeps.push(ms);
      c.t += ms;
      return Promise.resolve();
    },
    random: () => random,
  };
  return c;
}

const OK: CallResult = {
  ok: true,
  latencyMs: 10,
  response: {
    content: [{ type: "text", text: "hi" }],
    stop_reason: "end_turn",
    usage: { input_tokens: 1, output_tokens: 1 },
  },
};
const fail = (provider: ProviderId, e: Partial<ProviderErrorInfo>): CallResult => ({
  ok: false,
  latencyMs: 5,
  error: { provider, status: 500, message: "err", ...e },
});
const transient = (p: ProviderId) => fail(p, { status: 500, kind: "transient" });

const creds = [
  new Credential("anthropic", "primary", "sk-ant-primary-xxxxxxxxxxxx"),
  new Credential("anthropic", "secondary", "sk-ant-secondary-xxxxxxxxxx"),
  new Credential("openai", "primary", "sk-openai-primary-xxxxxxxxxx"),
];
const plan: ProviderPlan[] = [
  { provider: "anthropic", model: "claude-sonnet-5-5" },
  { provider: "openai", model: "gpt-5.4-mini" },
];

function scripted(script: Record<string, CallResult[]>) {
  const calls: string[] = [];
  return {
    calls,
    invoke: (p: ProviderPlan, c: Credential, _timeout: number): Promise<CallResult> => {
      const k = `${p.provider}/${c.alias}`;
      calls.push(k);
      const q = script[k] ?? [];
      return Promise.resolve(q.length > 1 ? q.shift()! : q[0] ?? transient(p.provider));
    },
  };
}

function run(script: Record<string, CallResult[]>, over: Partial<Parameters<typeof runWithFallback>[0]> = {}) {
  const s = scripted(script);
  const clock = (over.clock as ReturnType<typeof fakeClock>) ?? fakeClock();
  const health = (over.health as InMemoryHealthStore) ?? new InMemoryHealthStore();
  const breakers = over.breakers ?? new BreakerRegistry(new InMemoryBreakerStore(), { now: clock.now });
  const promise = runWithFallback({
    plan,
    credentials: creds,
    health,
    breakers,
    attemptsPerCredential: 3,
    deadlineAt: clock.now() + 45_000,
    clock,
    invoke: s.invoke,
    ...over,
  });
  return { promise, calls: s.calls, health, clock, breakers };
}

// ---------------------------------------------------------------------------
// backoff
// ---------------------------------------------------------------------------

Deno.test("backoff: full jitter bounded by min(cap, base*2^n)", () => {
  for (let n = 0; n < 8; n++) {
    const ceiling = Math.min(8000, 500 * 2 ** n);
    for (const r of [0, 0.25, 0.5, 0.999999]) {
      const d = backoffDelayMs(n, { random: () => r });
      assert(d >= 0 && d <= ceiling, `attempt ${n} r ${r} -> ${d}`);
    }
    assertEquals(backoffDelayMs(n, { random: () => 0 }), 0);
  }
  assertEquals(backoffDelayMs(10, { random: () => 0.999999 }), 7999);
});

Deno.test("backoff: Retry-After honoured as a floor", () => {
  assertEquals(backoffDelayMs(0, { random: () => 0.1, retryAfterMs: 5000 }), 5000);
  // jitter larger than Retry-After wins
  assertEquals(backoffDelayMs(4, { random: () => 0.9, retryAfterMs: 100 }), 7200);
});

Deno.test("backoff: never exceeds remaining deadline", () => {
  assertEquals(backoffDelayMs(3, { random: () => 0.99, remainingMs: 120 }), 120);
  assertEquals(backoffDelayMs(0, { retryAfterMs: 10_000, remainingMs: 2_000 }), 2_000);
  assertEquals(backoffDelayMs(0, { random: () => 0.5, remainingMs: -5 }), 0);
});

// ---------------------------------------------------------------------------
// withRetry
// ---------------------------------------------------------------------------

Deno.test("withRetry: transient retried then succeeds", async () => {
  const clock = fakeClock();
  const error: ProviderErrorInfo = { provider: "anthropic", status: 529, kind: "transient", message: "overloaded" };
  let n = 0;
  const r = await withRetry("anthropic", () => {
    n++;
    return Promise.resolve(n < 3 ? { ok: false as const, error } : { ok: true as const, value: "done" });
  }, { maxAttempts: 3, deadlineAt: clock.now() + 45_000, clock });
  assert(r.ok);
  assertEquals(r.attempts, 3);
  assertEquals(clock.sleeps.length, 2);
});

Deno.test("withRetry: honours short Retry-After, stops on long Retry-After and bad_request", async () => {
  const clock = fakeClock();
  const short = {
    provider: "openai" as const,
    status: 429,
    kind: "rate_limited" as const,
    message: "x",
    retryAfterMs: 3000,
  };
  let n = 0;
  const r = await withRetry(
    "openai",
    () => Promise.resolve(++n === 1 ? { ok: false as const, error: short } : { ok: true as const, value: 1 }),
    {
      maxAttempts: 3,
      deadlineAt: clock.now() + 45_000,
      clock,
    },
  );
  assert(r.ok);
  assertEquals(clock.sleeps, [3000]);

  const long = { ...short, retryAfterMs: 30_000 };
  const r2 = await withRetry("openai", () => Promise.resolve({ ok: false as const, error: long }), {
    maxAttempts: 3,
    deadlineAt: clock.now() + 45_000,
    clock,
  });
  assertFalse(r2.ok);
  assertEquals(r2.attempts, 1);

  const bad = { provider: "openai" as const, status: 400, kind: "bad_request" as const, message: "bad" };
  const r3 = await withRetry("openai", () => Promise.resolve({ ok: false as const, error: bad }), {
    maxAttempts: 3,
    deadlineAt: clock.now() + 45_000,
    clock,
  });
  assertFalse(r3.ok);
  assertEquals(r3.attempts, 1);
});

Deno.test("withRetry: respects deadline", async () => {
  const clock = fakeClock(0, 0.99);
  let n = 0;
  const r = await withRetry("gemini", () => {
    n++;
    clock.t += 400; // each call takes 400 ms
    return Promise.resolve({
      ok: false as const,
      error: { provider: "gemini" as const, status: 503, kind: "transient" as const, message: "x" },
    });
  }, { maxAttempts: 3, deadlineAt: 500, clock });
  assertFalse(r.ok);
  assert(n <= 2);
  assert(clock.t <= 900);
});

// ---------------------------------------------------------------------------
// runWithFallback
// ---------------------------------------------------------------------------

Deno.test("fallback: single transient failure retried on SAME credential, not rotated", async () => {
  const { promise, calls, health } = run({ "anthropic/primary": [transient("anthropic"), OK] });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.provider, "anthropic");
  assertEquals(r.alias, "primary");
  assertEquals(r.attempts, 2);
  assertFalse(r.fallbackUsed);
  assertEquals(calls, ["anthropic/primary", "anthropic/primary"]);
  assertEquals((await health.get("anthropic", "primary"))?.status, "ok");
});

Deno.test("fallback: transient retries exhausted -> next PROVIDER (not next credential), breaker counts", async () => {
  const { promise, calls, breakers } = run({ "anthropic/primary": [transient("anthropic")], "openai/primary": [OK] });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.provider, "openai");
  assert(r.fallbackUsed);
  assertEquals(r.attempts, 4);
  assertEquals(calls, ["anthropic/primary", "anthropic/primary", "anthropic/primary", "openai/primary"]);
  assertFalse(calls.includes("anthropic/secondary"));
  assertEquals((await breakers.get("anthropic")).snapshot().consecutive_failures, 1);
});

Deno.test("fallback: invalid key -> marked invalid, next credential of same provider", async () => {
  const { promise, calls, health } = run({
    "anthropic/primary": [fail("anthropic", { status: 401, kind: "invalid_credential", message: "invalid x-api-key" })],
    "anthropic/secondary": [OK],
  });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.alias, "secondary");
  assertFalse(r.fallbackUsed);
  assertEquals(calls, ["anthropic/primary", "anthropic/secondary"]);
  assertEquals((await health.get("anthropic", "primary"))?.status, "invalid");
});

Deno.test("fallback: quota exhausted -> cooldown + next credential", async () => {
  const clock = fakeClock();
  const { promise, calls, health } = run({
    "anthropic/primary": [
      fail("anthropic", { status: 400, kind: "quota_exhausted", message: "credit balance too low" }),
    ],
    "anthropic/secondary": [OK],
  }, { clock });
  const r = await promise;
  assert(r.ok);
  assertEquals(calls, ["anthropic/primary", "anthropic/secondary"]);
  const h = await health.get("anthropic", "primary");
  assertEquals(h?.status, "quota_exhausted");
  assertEquals(Date.parse(h!.cooldown_until!), clock.now() + 3_600_000);
});

Deno.test("fallback: long Retry-After -> rate_limited cooldown + next credential", async () => {
  const clock = fakeClock();
  const { promise, calls, health } = run({
    "anthropic/primary": [fail("anthropic", { status: 429, kind: "rate_limited", retryAfterMs: 90_000 })],
    "anthropic/secondary": [OK],
  }, { clock });
  const r = await promise;
  assert(r.ok);
  assertEquals(calls, ["anthropic/primary", "anthropic/secondary"]);
  const h = await health.get("anthropic", "primary");
  assertEquals(h?.status, "rate_limited");
  assertEquals(Date.parse(h!.cooldown_until!), clock.now() + 90_000);
});

Deno.test("fallback: all credentials of a provider exhausted -> next provider", async () => {
  const { promise, calls } = run({
    "anthropic/primary": [fail("anthropic", { status: 401, kind: "invalid_credential" })],
    "anthropic/secondary": [fail("anthropic", { status: 400, kind: "quota_exhausted" })],
    "openai/primary": [OK],
  });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.provider, "openai");
  assert(r.fallbackUsed);
  assertEquals(calls, ["anthropic/primary", "anthropic/secondary", "openai/primary"]);
});

Deno.test("fallback: bad_request stops immediately without rotation", async () => {
  const { promise, calls, health } = run({
    "anthropic/primary": [fail("anthropic", { status: 400, kind: "bad_request", message: "messages: bad" })],
    "openai/primary": [OK],
  });
  const r = await promise;
  assertFalse(r.ok);
  assertEquals(r.code, "invalid_request");
  assertEquals(calls, ["anthropic/primary"]);
  assertEquals(await health.get("anthropic", "primary"), null);
});

Deno.test("fallback: credentials in cooldown or invalid are skipped", async () => {
  const clock = fakeClock();
  const health = new InMemoryHealthStore();
  await health.markFailure("anthropic", "primary", "quota_exhausted", new Date(clock.now() + 60_000), "q");
  await health.markFailure("anthropic", "secondary", "invalid", null, "bad");
  const { promise, calls } = run({ "openai/primary": [OK] }, { clock, health });
  const r = await promise;
  assert(r.ok);
  assertEquals(calls, ["openai/primary"]);
  // expired cooldown is usable again
  assert(
    isCredentialAvailable({
      ...(await health.get("anthropic", "primary"))!,
      cooldown_until: new Date(clock.now() - 1).toISOString(),
    }, clock.now()),
  );
});

Deno.test("fallback: everything unavailable -> providers_unavailable with retry_after", async () => {
  const clock = fakeClock();
  const health = new InMemoryHealthStore();
  await health.markFailure("anthropic", "primary", "quota_exhausted", new Date(clock.now() + 30_000), "q");
  await health.markFailure("anthropic", "secondary", "rate_limited", new Date(clock.now() + 10_500), "r");
  await health.markFailure("openai", "primary", "invalid", null, "i");
  const { promise, calls } = run({}, { clock, health });
  const r = await promise;
  assertFalse(r.ok);
  assertEquals(r.code, "providers_unavailable");
  assertEquals(r.retryAfterS, 11);
  assertEquals(calls, []);
});

Deno.test("fallback: all providers transient -> upstream_error", async () => {
  const { promise } = run({});
  const r = await promise;
  assertFalse(r.ok);
  assertEquals(r.code, "upstream_error");
});

Deno.test("fallback: no configured provider -> no_provider_configured", async () => {
  const { promise } = run({}, { credentials: [] });
  const r = await promise;
  assertFalse(r.ok);
  assertEquals(r.code, "no_provider_configured");
});

Deno.test("fallback: timeouts past the deadline -> timeout", async () => {
  const clock = fakeClock();
  const s = scripted({});
  const r = await runWithFallback({
    plan,
    credentials: creds,
    health: new InMemoryHealthStore(),
    breakers: new BreakerRegistry(null, { now: clock.now }),
    attemptsPerCredential: 3,
    deadlineAt: clock.now() + 1000,
    clock,
    invoke: (p, c, t) => {
      clock.t += t; // the call consumes all remaining time then times out
      return s.invoke(p, c, t).then(() => fail(p.provider, { status: 0, kind: "transient", code: "timeout" }));
    },
  });
  assertFalse(r.ok);
  assertEquals(r.code, "timeout");
});

Deno.test("fallback: open circuit skips the provider", async () => {
  const clock = fakeClock();
  const store = new InMemoryBreakerStore();
  await store.save("anthropic", { state: "open", consecutive_failures: 5, opened_at: clock.now() });
  const { promise, calls } = run({ "openai/primary": [OK] }, {
    clock,
    breakers: new BreakerRegistry(store, { now: clock.now }),
  });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.provider, "openai");
  assertEquals(calls, ["openai/primary"]);
});

// ---------------------------------------------------------------------------
// Circuit breaker
// ---------------------------------------------------------------------------

Deno.test("circuit breaker: opens after 5 consecutive failures", () => {
  let t = 0;
  const b = new CircuitBreaker({ now: () => t });
  for (let i = 0; i < 4; i++) {
    b.recordFailure();
    assertEquals(b.state, "closed");
  }
  b.recordFailure();
  assertEquals(b.state, "open");
  assertFalse(b.canRequest());
  t += 59_999;
  assertEquals(b.state, "open");
});

Deno.test("circuit breaker: half-open after 60 s allows exactly one trial; success closes", () => {
  let t = 0;
  const b = new CircuitBreaker({ now: () => t });
  for (let i = 0; i < 5; i++) b.recordFailure();
  t += 60_000;
  assertEquals(b.state, "half_open");
  assert(b.canRequest());
  assertFalse(b.canRequest());
  b.recordSuccess();
  assertEquals(b.state, "closed");
  assertEquals(b.snapshot().consecutive_failures, 0);
  assert(b.canRequest());
});

Deno.test("circuit breaker: failure in half-open re-opens", () => {
  let t = 0;
  const b = new CircuitBreaker({ now: () => t });
  for (let i = 0; i < 5; i++) b.recordFailure();
  t += 60_000;
  assert(b.canRequest());
  b.recordFailure();
  assertEquals(b.state, "open");
  t += 60_000;
  assertEquals(b.state, "half_open");
});

Deno.test("circuit breaker: success resets the failure streak", () => {
  const b = new CircuitBreaker({ now: () => 0 });
  for (let i = 0; i < 4; i++) b.recordFailure();
  b.recordSuccess();
  for (let i = 0; i < 4; i++) b.recordFailure();
  assertEquals(b.state, "closed");
});

Deno.test("breaker registry persists snapshots", async () => {
  let t = 0;
  const store = new InMemoryBreakerStore();
  const reg = new BreakerRegistry(store, { now: () => t });
  const b = await reg.get("gemini");
  for (let i = 0; i < 5; i++) b.recordFailure();
  await reg.persist("gemini");
  assertEquals(store.data.get("gemini")?.state, "open");
  const fresh = await new BreakerRegistry(store, { now: () => t }).get("gemini");
  assertEquals(fresh.state, "open");
  t += 60_000;
  assertEquals(fresh.state, "half_open");
});

Deno.test("fallback: request_too_large -> next provider, no retry, no key or breaker penalty", async () => {
  const { promise, calls, health, breakers } = run({
    "anthropic/primary": [fail("anthropic", { status: 413, kind: "request_too_large", message: "Request too large" })],
    "openai/primary": [OK],
  });
  const r = await promise;
  assert(r.ok);
  assertEquals(r.provider, "openai");
  assertEquals(calls, ["anthropic/primary", "openai/primary"]);
  assertEquals(await health.get("anthropic", "primary"), null);
  assertEquals((await breakers.get("anthropic")).snapshot().consecutive_failures, 0);
});

Deno.test("fallback: request_too_large on the last provider -> upstream_error", async () => {
  const { promise } = run({
    "anthropic/primary": [fail("anthropic", { status: 401, kind: "invalid_credential" })],
    "anthropic/secondary": [fail("anthropic", { status: 401, kind: "invalid_credential" })],
    "openai/primary": [fail("openai", { status: 413, kind: "request_too_large", message: "Request too large" })],
  });
  const r = await promise;
  assertFalse(r.ok);
  if (!r.ok) {
    assertEquals(r.code, "upstream_error");
    assert(r.message.includes("too large"));
  }
});

Deno.test("fallback: a hanging primary leaves the reserve for the next provider", async () => {
  const clock = fakeClock();
  const timeouts: number[] = [];
  const s = {
    invoke: (p: ProviderPlan, _c: Credential, timeoutMs: number): Promise<CallResult> => {
      timeouts.push(timeoutMs);
      if (p.provider === "anthropic") {
        clock.t += timeoutMs; // hangs until its timeout
        return Promise.resolve(fail("anthropic", { status: 0, kind: "transient", code: "timeout" }));
      }
      return Promise.resolve(OK);
    },
  };
  const r = await runWithFallback({
    plan,
    credentials: creds,
    health: new InMemoryHealthStore(),
    breakers: new BreakerRegistry(new InMemoryBreakerStore(), { now: clock.now }),
    attemptsPerCredential: 3,
    deadlineAt: clock.now() + 45_000,
    clock,
    invoke: s.invoke,
  });
  assert(r.ok);
  assertEquals(r.provider, "openai");
  assertEquals(timeouts[0], 30_000);
  assertEquals(timeouts[timeouts.length - 1], 15_000);
});
