// JSON + CORS helpers and the error envelope of the wire contract.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export type ErrorCode =
  | "unauthorized"
  | "invalid_request"
  | "rate_limited"
  | "budget_exceeded"
  | "no_provider_configured"
  | "providers_unavailable"
  | "upstream_error"
  | "timeout"
  | "conflict"
  | "internal";

export const STATUS_BY_CODE: Record<ErrorCode, number> = {
  unauthorized: 401,
  invalid_request: 400,
  rate_limited: 429,
  budget_exceeded: 402,
  no_provider_configured: 503,
  providers_unavailable: 503,
  upstream_error: 502,
  timeout: 504,
  conflict: 409,
  internal: 500,
};

export function jsonResponse(status: number, body: unknown, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8", ...extraHeaders },
  });
}

export function errorResponse(code: ErrorCode, message: string, retryAfterS?: number): Response {
  const error: Record<string, unknown> = { code, message };
  const headers: Record<string, string> = {};
  if (retryAfterS !== undefined && retryAfterS > 0) {
    error.retry_after_s = retryAfterS;
    headers["Retry-After"] = String(retryAfterS);
  }
  return jsonResponse(STATUS_BY_CODE[code], { error }, headers);
}

/** Returns a 204 preflight response for OPTIONS, otherwise null. */
export function handleOptions(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response(null, { status: 204, headers: corsHeaders }) : null;
}
