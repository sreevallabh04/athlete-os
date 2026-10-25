// Small pure helpers shared by provider adapters.
import type { JsonObject } from "./types.ts";

export function isPlainObject(v: unknown): v is JsonObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function safeJsonParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/**
 * Parses Go-style / Google-style durations: "12s", "1.5s", "20ms", "6m0s",
 * "1h2m3s". Returns milliseconds or undefined.
 */
export function parseDurationMs(value: string | null | undefined): number | undefined {
  if (!value) return undefined;
  const s = value.trim();
  if (s === "") return undefined;
  if (/^\d+(\.\d+)?$/.test(s)) return Math.round(Number(s) * 1000); // bare seconds
  const re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  let total = 0;
  let consumed = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    const n = Number(m[1]);
    switch (m[2]) {
      case "h":
        total += n * 3_600_000;
        break;
      case "m":
        total += n * 60_000;
        break;
      case "s":
        total += n * 1000;
        break;
      case "ms":
        total += n;
        break;
    }
    consumed += m[0].length;
  }
  if (consumed !== s.length) return undefined;
  return Math.round(total);
}

/** Retry-After: delta-seconds or HTTP-date. */
export function parseRetryAfterHeader(
  value: string | null | undefined,
  nowMs: number = Date.now(),
): number | undefined {
  if (!value) return undefined;
  const v = value.trim();
  if (/^\d+(\.\d+)?$/.test(v)) return Math.max(0, Math.round(Number(v) * 1000));
  const date = Date.parse(v);
  if (!Number.isNaN(date)) return Math.max(0, date - nowMs);
  return undefined;
}

/** Sent instead of pixels to providers that cannot take image input. */
export const IMAGE_PLACEHOLDER = "[Image omitted: this AI provider cannot view images.]";

export function truncate(text: string, max = 500): string {
  return text.length <= max ? text : `${text.slice(0, max)}…`;
}

/** Merges consecutive messages with the same role (some providers require alternation). */
export function mergeConsecutive<T extends { role: string; content: unknown[] }>(msgs: T[]): T[] {
  const out: T[] = [];
  for (const m of msgs) {
    if (m.content.length === 0) continue;
    const last = out[out.length - 1];
    if (last && last.role === m.role) {
      out[out.length - 1] = { ...last, content: [...last.content, ...m.content] };
    } else {
      out.push({ ...m, content: [...m.content] });
    }
  }
  return out;
}

export function toInt(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? Math.max(0, Math.round(n)) : 0;
}
