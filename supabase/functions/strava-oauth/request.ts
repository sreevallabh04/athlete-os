// Request parsing for strava-oauth (pure, unit-tested in request_test.ts).
import { readBodyLimited } from "../_shared/validate.ts";

export const STRAVA_BODY_LIMIT_BYTES = 4096;
/** Strava authorization codes are short hex strings; anything huge is junk. */
const MAX_CODE_CHARS = 256;
const MAX_SCOPE_CHARS = 200;

export type StravaRequest =
  | { action: "exchange"; code: string; redirect_uri: string; scope: string | null }
  | { action: "refresh" }
  | { action: "revoke" };

export type ParseResult =
  | { ok: true; value: StravaRequest }
  | { ok: false; status: number; error: string; message?: string };

const bad = (error: string, message?: string): ParseResult => ({ ok: false, status: 400, error, message });

/** Validates a parsed JSON body. Error codes match what the app already maps. */
export function parseStravaRequest(body: unknown, allowedRedirect: string): ParseResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return bad("invalid_request", "Body must be a JSON object.");
  }
  const b = body as Record<string, unknown>;
  switch (b.action) {
    case "exchange": {
      if (typeof b.code !== "string" || b.code.length === 0) return bad("invalid_request", "Missing code.");
      if (b.code.length > MAX_CODE_CHARS) return bad("invalid_request", "Invalid code.");
      if (b.redirect_uri !== allowedRedirect) return bad("invalid_redirect_uri");
      let scope: string | null = null;
      if (b.scope !== undefined && b.scope !== null) {
        if (typeof b.scope !== "string" || b.scope.length > MAX_SCOPE_CHARS) {
          return bad("invalid_request", "Invalid scope.");
        }
        scope = b.scope.length > 0 ? b.scope : null;
      }
      return { ok: true, value: { action: "exchange", code: b.code, redirect_uri: allowedRedirect, scope } };
    }
    case "refresh":
      return { ok: true, value: { action: "refresh" } };
    case "revoke":
      return { ok: true, value: { action: "revoke" } };
    default:
      return bad("invalid_action", "action must be exchange, refresh or revoke.");
  }
}

/** Reads (byte-capped) and parses the request body. */
export async function readStravaRequest(req: Request, allowedRedirect: string): Promise<ParseResult> {
  const raw = await readBodyLimited(req, STRAVA_BODY_LIMIT_BYTES);
  if (raw === null) return bad("invalid_request", "Body is too large.");
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return bad("invalid_request", "Body must be JSON.");
  }
  return parseStravaRequest(body, allowedRedirect);
}
