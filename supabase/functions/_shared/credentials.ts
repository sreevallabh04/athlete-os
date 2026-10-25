// Provider credentials from function secrets. Key values never leave this
// module in serialised form: Credential.toJSON / inspect omit the key.
import { type EnvFn, isProviderId, PROVIDER_IDS, type ProviderId } from "./providers/types.ts";

export type CredentialAlias = "primary" | "secondary";
export const ALIASES: readonly CredentialAlias[] = ["primary", "secondary"];

const ENV_NAMES: Record<ProviderId, Record<CredentialAlias, string>> = {
  anthropic: { primary: "ANTHROPIC_API_KEY", secondary: "ANTHROPIC_API_KEY_SECONDARY" },
  openai: { primary: "OPENAI_API_KEY", secondary: "OPENAI_API_KEY_SECONDARY" },
  gemini: { primary: "GEMINI_API_KEY", secondary: "GEMINI_API_KEY_SECONDARY" },
};

export const DEFAULT_MODELS: Record<ProviderId, string> = {
  anthropic: "claude-sonnet-5-5",
  openai: "gpt-5.4-mini",
  gemini: "gemini-3.8-flash",
};

const MODEL_ENV: Record<ProviderId, string> = {
  anthropic: "AI_DEFAULT_MODEL_ANTHROPIC",
  openai: "AI_DEFAULT_MODEL_OPENAI",
  gemini: "AI_DEFAULT_MODEL_GEMINI",
};

export const denoEnv: EnvFn = (name) => {
  try {
    return Deno.env.get(name);
  } catch {
    return undefined;
  }
};

export class Credential {
  readonly #key: string;
  constructor(readonly provider: ProviderId, readonly alias: CredentialAlias, key: string) {
    this.#key = key;
  }
  get key(): string {
    return this.#key;
  }
  toJSON(): { provider: ProviderId; alias: CredentialAlias } {
    return { provider: this.provider, alias: this.alias };
  }
  toString(): string {
    return `Credential(${this.provider}/${this.alias})`;
  }
  [Symbol.for("Deno.customInspect")](): string {
    return this.toString();
  }
}

export interface CredentialMeta {
  provider: ProviderId;
  alias: CredentialAlias;
}

export function loadCredentials(env: EnvFn = denoEnv): Credential[] {
  const out: Credential[] = [];
  for (const provider of PROVIDER_IDS) {
    for (const alias of ALIASES) {
      const v = env(ENV_NAMES[provider][alias])?.trim();
      if (v) out.push(new Credential(provider, alias, v));
    }
  }
  return out;
}

/** Configured credentials without key material. */
export function listConfigured(env: EnvFn = denoEnv): CredentialMeta[] {
  return loadCredentials(env).map((c) => c.toJSON());
}

/** All configured key values (for exact-match redaction). */
export function secretValues(env: EnvFn = denoEnv): string[] {
  return loadCredentials(env).map((c) => c.key);
}

export function providerOrder(env: EnvFn = denoEnv): ProviderId[] {
  const raw = env("AI_PROVIDER_ORDER");
  if (!raw) return [...PROVIDER_IDS];
  const seen = new Set<ProviderId>();
  for (const part of raw.split(",")) {
    const p = part.trim().toLowerCase();
    if (isProviderId(p)) seen.add(p);
  }
  return seen.size > 0 ? [...seen] : [...PROVIDER_IDS];
}

export function defaultModel(provider: ProviderId, env: EnvFn = denoEnv): string {
  return env(MODEL_ENV[provider])?.trim() || DEFAULT_MODELS[provider];
}
