// Port of lib/core/util/redact.dart plus exact-value scrubbing of configured
// secrets. Every error that is logged, persisted or returned passes through
// redactAll().

const PATTERNS: RegExp[] = [
  /sk-ant-[A-Za-z0-9_\-]{10,}/g,
  /sk-[A-Za-z0-9_\-]{16,}/g,
  /AIza[0-9A-Za-z_\-]{20,}/g,
  /bearer\s+[A-Za-z0-9._\-]{10,}/gi,
  /eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}/g,
];

// key=value / "key": "value" assignments. Group 3 is the secret value.
const ASSIGNMENT =
  /\b(x-api-key|x-goog-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password|token|key)\b(["']?\s*[:=]\s*["']?)([^"'\s&,}]{6,})/gi;

/** Removes anything that looks like a credential. */
export function redactSecrets(input: string): string {
  let out = input;
  out = out.replace(ASSIGNMENT, (_m, k: string, sep: string) => `${k}${sep}[REDACTED]`);
  for (const p of PATTERNS) out = out.replace(p, "[REDACTED]");
  return out;
}

/** Replaces exact occurrences of known secret values (e.g. configured API keys). */
export function redactKnownSecrets(text: string, secrets: readonly (string | undefined | null)[]): string {
  let out = text;
  for (const s of secrets) {
    if (!s || s.length < 6) continue;
    out = out.split(s).join("[REDACTED]");
  }
  return out;
}

/** Known secrets first (exact), then pattern-based redaction, then truncation. */
export function redactAll(
  text: string,
  secrets: readonly (string | undefined | null)[] = [],
  maxLength = 500,
): string {
  const out = redactSecrets(redactKnownSecrets(text, secrets));
  return out.length > maxLength ? `${out.slice(0, maxLength)}…` : out;
}
