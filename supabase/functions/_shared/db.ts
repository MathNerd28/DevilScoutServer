import { createClient } from "supabase";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// need service role to access etags (in a non-public schema)
export function createSupabaseClient(serviceRole: boolean = false) {
  return createClient(SUPABASE_URL, serviceRole ? SUPABASE_SERVICE_ROLE_KEY : SUPABASE_ANON_KEY);
}

export function isServiceRole(authHeader: string) {
  return authHeader === SUPABASE_SERVICE_ROLE_KEY;
}
