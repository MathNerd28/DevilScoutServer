import { createSupabaseClient } from "./db.ts";

export const supabase = createSupabaseClient(false);
