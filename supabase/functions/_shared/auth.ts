// Supabase auth helpers for edge functions.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.75.0";
import { denoEnv } from "./credentials.ts";
import type { EnvFn } from "./providers/types.ts";

export class AuthError extends Error {
  readonly status = 401;
  constructor(message = "Authentication required") {
    super(message);
    this.name = "AuthError";
  }
}

/** Resolves the caller's user id from the Authorization header or throws AuthError (401). */
export async function getUser(req: Request, env: EnvFn = denoEnv): Promise<string> {
  const authorization = req.headers.get("Authorization");
  if (!authorization || !/^Bearer\s+\S+/i.test(authorization)) throw new AuthError();
  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY") ?? env("SUPABASE_PUBLISHABLE_KEY");
  if (!url || !anonKey) throw new Error("Supabase environment is not configured");
  const client = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user?.id) throw new AuthError("Invalid or expired session");
  return data.user.id;
}

let cachedService: SupabaseClient | null = null;

/** Service-role client (bypasses RLS). Server-only tables are accessed through it. */
export function serviceClient(env: EnvFn = denoEnv): SupabaseClient {
  if (cachedService) return cachedService;
  const url = env("SUPABASE_URL");
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Supabase service environment is not configured");
  cachedService = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return cachedService;
}
