// generate-overview — ARCHITECTURE.md §4, §2a.
// Client call, POST { family_id }. Only invoked when the PARENT's own
// llm_mode = server (the parent initiates this, so their setting governs
// it — §2a's per-profile rule). Uses the user-scoped client (not admin)
// for every read: RLS already enforces "parent role, own family" for
// everything this needs, no reason to bypass it here.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { generateOverviewCore } from "../_shared/generate-overview-core.ts";

interface RequestBody {
  family_id: string;
  period_start?: string;
  period_end?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonResponse({ error: "Missing Authorization header" }, 401);

  const supabase = createUserClient(authHeader);
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }
  if (!body.family_id) return jsonResponse({ error: "family_id is required" }, 400);

  // Confirm caller is a parent in this family — belt-and-suspenders on top
  // of RLS, which would return empty results rather than a clear error if
  // this weren't true.
  const { data: callerProfile } = await supabase
    .from("profiles")
    .select("role, family_id, llm_mode")
    .eq("id", user.id)
    .single();

  // Case-insensitive: Postgres returns UUIDs lowercase, clients (e.g.
  // Swift's UUID.uuidString) commonly send uppercase — bare `!==` rejects
  // valid requests. Found live (2026-08-25) via be1 testing.
  if (
    !callerProfile ||
    callerProfile.role !== "parent" ||
    callerProfile.family_id.toLowerCase() !== body.family_id.toLowerCase()
  ) {
    return jsonResponse({ error: "forbidden" }, 403);
  }
  if (callerProfile.llm_mode !== "server") {
    return jsonResponse({ error: "caller_is_on_device_mode" }, 400);
  }

  try {
    const inserted = await generateOverviewCore(
      supabase,
      body.family_id,
      body.period_start ?? null,
      body.period_end ?? null,
    );
    return jsonResponse(inserted);
  } catch (err) {
    console.error("generate-overview: generation failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
