import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { redactAll, redactKnownSecrets, redactSecrets } from "./redact.ts";

Deno.test("redact: provider key formats", () => {
  const s = redactSecrets(
    "keys sk-ant-api03-ABCDEFGHIJKLMNOP and sk-proj-ABCDEFGHIJKLMNOPQRST and AIzaSyA1234567890abcdefghijklmn",
  );
  assertFalse(s.includes("sk-ant-api03"));
  assertFalse(s.includes("sk-proj-ABCDEFGHIJ"));
  assertFalse(s.includes("AIzaSy"));
  assertEquals(s.match(/\[REDACTED\]/g)?.length, 3);
});

Deno.test("redact: bearer tokens and JWTs", () => {
  const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
  const s = redactSecrets(`Authorization: Bearer abcdefghijklmnop12345 token ${jwt}`);
  assertFalse(s.includes("abcdefghijklmnop12345"));
  assertFalse(s.includes("eyJhbGci"));
});

Deno.test("redact: key/value assignments", () => {
  const s = redactSecrets(
    'url?key=AbC123xyz789&x=1 {"api_key": "supersecretvalue"} password=hunter22 client_secret: s3cr3tv4lue token=abcdef123',
  );
  assert(s.includes("key=[REDACTED]"));
  assert(s.includes('"api_key": "[REDACTED]'));
  assert(s.includes("password=[REDACTED]"));
  assert(s.includes("client_secret: [REDACTED]"));
  assert(s.includes("token=[REDACTED]"));
  assertFalse(/supersecretvalue|hunter22|s3cr3tv4lue|abcdef123|AbC123xyz789/.test(s));
});

Deno.test("redact: ordinary provider error text is preserved", () => {
  const msg = "prompt is too long: 210000 tokens > 200000 maximum; max_tokens: 64000 exceeds limit";
  assertEquals(redactSecrets(msg), msg);
  assertEquals(
    redactSecrets("API key not valid. Please pass a valid API key."),
    "API key not valid. Please pass a valid API key.",
  );
});

Deno.test("redact: exact known secrets and truncation", () => {
  const secret = "weird-format-secret-value";
  assertEquals(redactKnownSecrets(`leaked ${secret}!`, [secret, undefined, ""]), "leaked [REDACTED]!");
  const long = "x".repeat(1000);
  assertEquals(redactAll(long, [], 10), `${"x".repeat(10)}…`);
  assertFalse(redactAll(`boom ${secret}`, [secret]).includes(secret));
});
