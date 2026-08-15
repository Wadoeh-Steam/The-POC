// Service-role client — bypasses RLS. Only for use inside Edge Functions,
// never expose this key to a client. See ARCHITECTURE.md §4.
import { createClient } from "jsr:@supabase/supabase-js@2";

export function createAdminClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
}

// Client scoped to the caller's own JWT — respects RLS. Use this instead
// of the admin client whenever a function is just doing something the
// caller is already allowed to do themselves (e.g. reading their own
// family's data) — narrower privilege than the admin client.
export function createUserClient(authHeader: string) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    },
  );
}
