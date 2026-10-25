import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { callProvider } from "./call.ts";
import { anthropicAdapter } from "./anthropic.ts";
import { classifyError } from "../resilience.ts";
import { conversation, input } from "../testing.ts";

const KEY = "sk-ant-api03-SECRETSECRETSECRET";

Deno.test("callProvider: success parses response", async () => {
  const fetchFn = (_url: string | URL | Request, _init?: RequestInit) =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          content: [{ type: "text", text: "OK" }],
          stop_reason: "end_turn",
          usage: { input_tokens: 3, output_tokens: 1 },
        }),
        { status: 200 },
      ),
    );
  const r = await callProvider(anthropicAdapter, input(conversation("anthropic")), KEY, { timeoutMs: 1000, fetchFn });
  assert(r.ok);
  if (r.ok) assertEquals(r.response.content, [{ type: "text", text: "OK" }]);
});

Deno.test("callProvider: error text echoing the key is redacted", async () => {
  const fetchFn = () =>
    Promise.resolve(
      new Response(JSON.stringify({ error: { type: "authentication_error", message: `bad key ${KEY}` } }), {
        status: 401,
      }),
    );
  const r = await callProvider(anthropicAdapter, input(conversation("anthropic")), KEY, { timeoutMs: 1000, fetchFn });
  assertFalse(r.ok);
  if (!r.ok) {
    assertEquals(classifyError(r.error), "invalid_credential");
    assertFalse(r.error.message.includes("SECRET"));
  }
});

Deno.test("callProvider: timeout -> transient/timeout", async () => {
  const fetchFn = (_u: string | URL | Request, init?: RequestInit) =>
    new Promise<Response>((_res, rej) => {
      init?.signal?.addEventListener("abort", () => rej(init.signal!.reason));
    });
  const r = await callProvider(anthropicAdapter, input(conversation("anthropic")), KEY, { timeoutMs: 20, fetchFn });
  assertFalse(r.ok);
  if (!r.ok) {
    assertEquals(r.error.kind, "transient");
    assertEquals(r.error.code, "timeout");
  }
});

Deno.test("callProvider: network error and malformed JSON are transient", async () => {
  const net = await callProvider(anthropicAdapter, input(conversation("anthropic")), KEY, {
    timeoutMs: 1000,
    fetchFn: () => Promise.reject(new TypeError(`connect failed ${KEY}`)),
  });
  assertFalse(net.ok);
  if (!net.ok) {
    assertEquals(net.error.code, "network");
    assertFalse(net.error.message.includes("SECRET"));
  }
  const bad = await callProvider(anthropicAdapter, input(conversation("anthropic")), KEY, {
    timeoutMs: 1000,
    fetchFn: () => Promise.resolve(new Response("not json", { status: 200 })),
  });
  assertFalse(bad.ok);
  if (!bad.ok) assertEquals(bad.error.kind, "transient");
});
