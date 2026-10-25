import { assertEquals, assertFalse } from "jsr:@std/assert@1";
import { defaultModel, listConfigured, loadCredentials, providerOrder } from "./credentials.ts";

const env = (vars: Record<string, string>) => (n: string) => vars[n];

Deno.test("credentials: loads configured keys with aliases", () => {
  const creds = loadCredentials(env({
    ANTHROPIC_API_KEY: "sk-ant-aaaaaaaaaaaaaaa",
    ANTHROPIC_API_KEY_SECONDARY: "sk-ant-bbbbbbbbbbbbbbb",
    OPENAI_API_KEY: "  ",
    GEMINI_API_KEY_SECONDARY: "AIzaZZZZ",
  }));
  assertEquals(creds.map((c) => `${c.provider}/${c.alias}`), [
    "anthropic/primary",
    "anthropic/secondary",
    "gemini/secondary",
  ]);
  assertEquals(creds[0].key, "sk-ant-aaaaaaaaaaaaaaa");
});

Deno.test("credentials: key never serialised", () => {
  const vars = { OPENAI_API_KEY: "sk-very-secret-value-123456" };
  const [c] = loadCredentials(env(vars));
  const json = JSON.stringify({ c, list: [c] });
  assertFalse(json.includes("sk-very-secret"));
  assertFalse(Deno.inspect(c).includes("sk-very-secret"));
  assertFalse(String(c).includes("sk-very-secret"));
  assertFalse(Object.keys(c).includes("key"));
  assertEquals(listConfigured(env(vars)), [{ provider: "openai", alias: "primary" }]);
});

Deno.test("credentials: provider order and default models", () => {
  assertEquals(providerOrder(env({})), ["anthropic", "openai", "gemini", "groq"]);
  assertEquals(providerOrder(env({ AI_PROVIDER_ORDER: "gemini, OPENAI,bogus,gemini" })), ["gemini", "openai"]);
  assertEquals(providerOrder(env({ AI_PROVIDER_ORDER: "bogus" })), ["anthropic", "openai", "gemini", "groq"]);
  assertEquals(providerOrder(env({ AI_PROVIDER_ORDER: "gemini,groq" })), ["gemini", "groq"]);
  assertEquals(defaultModel("groq", env({})), "openai/gpt-oss-120b");
  assertEquals(defaultModel("groq", env({ AI_DEFAULT_MODEL_GROQ: "openai/gpt-oss-20b" })), "openai/gpt-oss-20b");
  assertEquals(defaultModel("anthropic", env({})), "claude-sonnet-5-5");
  assertEquals(defaultModel("openai", env({})), "gpt-5.4-mini");
  assertEquals(defaultModel("gemini", env({})), "gemini-3.8-flash");
  assertEquals(defaultModel("openai", env({ AI_DEFAULT_MODEL_OPENAI: "gpt-x" })), "gpt-x");
});

Deno.test("credentials: groq primary + secondary", () => {
  const creds = loadCredentials(env({ GROQ_API_KEY: "gsk_aaaaaaaaaaaaaaaa", GROQ_API_KEY_SECONDARY: "gsk_bbbbbbbbbbbb" }));
  assertEquals(creds.map((c) => `${c.provider}/${c.alias}`), ["groq/primary", "groq/secondary"]);
});
