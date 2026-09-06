// generate-weekly-overviews-batch — server-triggered by a Friday 19:00 WIB
// pg_cron job (migration 20260907000002_weekly_overview_cron.sql), NEVER
// invoked by the client. Generates this week's overview for every server-
// mode family that journaled at least once this week and doesn't already
// have one — moved off "the moment a parent opens Ringkasan" so "weekly
// overview" actually means once a week, landing before the weekend
// (product decision 2026-09-07). See RingkasanViewModel.swift's
// weeklyOverviewCutoff for the client-side mirror of this cutoff (used
// only as a missed-cron safety net there).
//
// Authorization: this acts across every family, not on behalf of one
// caller, so it can't reuse createUserClient's per-user RLS-respecting
// model. Deployed WITH normal JWT verification (no --no-verify-jwt) so
// Supabase's own gateway rejects anything not signed by this project —
// but that alone doesn't distinguish a signed-in parent's own JWT from a
// privileged caller, so this function additionally requires the exact
// service-role key, checked below. A regular parent's JWT passes the
// gateway but must NOT be able to trigger a mass-generation run (real LLM
// cost) across every family in the project.
//
// on_device parents are out of scope here on purpose (2026-09-07 product
// decision) — a server cron has no way to run their local model for them;
// their overview still only generates client-side, on-open, unchanged.

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { generateOverviewCore } from "../_shared/generate-overview-core.ts";

// Mirrors the client's currentWeekRange() (WeekViewModel.swift) — Monday
// 00:00 WIB through the following Monday 00:00 WIB. WIB (Asia/Jakarta) is
// a fixed UTC+7 offset, no DST, so this doesn't need a timezone database.
function currentWeekRangeWIB(now: Date): { start: string; end: string } {
  const WIB_OFFSET_MS = 7 * 60 * 60 * 1000;
  const wibNow = new Date(now.getTime() + WIB_OFFSET_MS);
  const daysSinceMonday = (wibNow.getUTCDay() + 6) % 7; // Mon=0 .. Sun=6
  const wibMidnight = Date.UTC(wibNow.getUTCFullYear(), wibNow.getUTCMonth(), wibNow.getUTCDate());
  const wibMonday = wibMidnight - daysSinceMonday * 24 * 60 * 60 * 1000;
  const startUtcMs = wibMonday - WIB_OFFSET_MS;
  const endUtcMs = startUtcMs + 7 * 24 * 60 * 60 * 1000;
  return { start: new Date(startUtcMs).toISOString(), end: new Date(endUtcMs).toISOString() };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey || authHeader !== `Bearer ${serviceKey}`) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const supabase = createAdminClient();
  const { start: periodStart, end: periodEnd } = currentWeekRangeWIB(new Date());

  const { data: serverModeParents, error: familiesError } = await supabase
    .from("profiles")
    .select("family_id")
    .eq("role", "parent")
    .eq("llm_mode", "server");

  if (familiesError) {
    console.error("generate-weekly-overviews-batch: failed to list families", familiesError);
    return jsonResponse({ error: "list_families_failed" }, 500);
  }

  const familyIds = [...new Set((serverModeParents ?? []).map((p) => p.family_id as string))];

  let generated = 0;
  let skipped = 0;
  let failed = 0;

  // Sequential, not parallel — this project's LLM fallback chain already
  // has to respect OpenRouter's free-tier rate cap (see llm.ts), and a
  // burst of N families hitting it at once is exactly the failure mode
  // that budget was designed around. Fine at today's family count; if this
  // ever needs to scale to many families, split across multiple scheduled
  // invocations rather than parallelizing here.
  for (const familyId of familyIds) {
    try {
      const [{ count: entryCount }, { data: existing }] = await Promise.all([
        supabase
          .from("parent_log_entries")
          .select("id", { count: "exact", head: true })
          .eq("family_id", familyId)
          .eq("context_complete", true)
          .gte("timestamp", periodStart)
          .lt("timestamp", periodEnd),
        supabase
          .from("overviews")
          .select("id")
          .eq("family_id", familyId)
          .eq("period_start", periodStart)
          .maybeSingle(),
      ]);

      if (!entryCount || existing) {
        skipped++;
        continue;
      }

      await generateOverviewCore(supabase, familyId, periodStart, periodEnd);
      generated++;
    } catch (err) {
      failed++;
      console.error(`generate-weekly-overviews-batch: failed for family ${familyId}`, err);
    }
  }

  return jsonResponse({ period_start: periodStart, period_end: periodEnd, families: familyIds.length, generated, skipped, failed });
});
