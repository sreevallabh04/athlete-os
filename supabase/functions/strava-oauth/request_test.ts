import { assertEquals } from "jsr:@std/assert@1";
import { parseStravaRequest, readStravaRequest } from "./request.ts";

const REDIRECT = "athleteos://localhost/strava";

Deno.test("strava-oauth request: valid actions", () => {
  assertEquals(parseStravaRequest({ action: "refresh" }, REDIRECT), { ok: true, value: { action: "refresh" } });
  assertEquals(parseStravaRequest({ action: "revoke" }, REDIRECT), { ok: true, value: { action: "revoke" } });
  assertEquals(
    parseStravaRequest(
      { action: "exchange", code: "abc123", redirect_uri: REDIRECT, scope: "read,activity:read_all" },
      REDIRECT,
    ),
    {
      ok: true,
      value: { action: "exchange", code: "abc123", redirect_uri: REDIRECT, scope: "read,activity:read_all" },
    },
  );
  const noScope = parseStravaRequest({ action: "exchange", code: "abc", redirect_uri: REDIRECT }, REDIRECT);
  assertEquals(noScope.ok && noScope.value.action === "exchange" ? noScope.value.scope : "x", null);
});

Deno.test("strava-oauth request: non-object bodies and bad types are 400s, not 500s", () => {
  for (const body of [null, [], "exchange", 42, true]) {
    const r = parseStravaRequest(body, REDIRECT);
    assertEquals(r.ok, false);
    if (!r.ok) assertEquals([r.status, r.error], [400, "invalid_request"]);
  }
  const cases: [unknown, string][] = [
    [{ action: "exchange", redirect_uri: REDIRECT }, "invalid_request"],
    [{ action: "exchange", code: 12345, redirect_uri: REDIRECT }, "invalid_request"],
    [{ action: "exchange", code: { $ne: 1 }, redirect_uri: REDIRECT }, "invalid_request"],
    [{ action: "exchange", code: "x".repeat(257), redirect_uri: REDIRECT }, "invalid_request"],
    [{ action: "exchange", code: "abc", redirect_uri: REDIRECT, scope: ["activity:read"] }, "invalid_request"],
    [{ action: "exchange", code: "abc", redirect_uri: REDIRECT, scope: 7 }, "invalid_request"],
    [{ action: "nope" }, "invalid_action"],
    [{}, "invalid_action"],
  ];
  for (const [body, error] of cases) {
    const r = parseStravaRequest(body, REDIRECT);
    assertEquals(r.ok ? "ok" : r.error, error, JSON.stringify(body));
  }
});

Deno.test("strava-oauth request: redirect_uri must match the allowlisted value exactly", () => {
  for (const redirect_uri of [undefined, "https://evil.example/cb", `${REDIRECT}/x`, REDIRECT.toUpperCase()]) {
    const r = parseStravaRequest({ action: "exchange", code: "abc", redirect_uri }, REDIRECT);
    assertEquals(r.ok ? "ok" : r.error, "invalid_redirect_uri");
  }
});

Deno.test("strava-oauth request: body is byte-capped and must be JSON", async () => {
  const big = new Request("http://x", {
    method: "POST",
    body: JSON.stringify({ action: "refresh", pad: "x".repeat(10_000) }),
  });
  const r1 = await readStravaRequest(big, REDIRECT);
  assertEquals(r1.ok ? "ok" : r1.error, "invalid_request");
  const r2 = await readStravaRequest(new Request("http://x", { method: "POST", body: "{nope" }), REDIRECT);
  assertEquals(r2.ok ? "ok" : r2.error, "invalid_request");
  const r3 = await readStravaRequest(
    new Request("http://x", { method: "POST", body: JSON.stringify({ action: "refresh" }) }),
    REDIRECT,
  );
  assertEquals(r3.ok, true);
});
