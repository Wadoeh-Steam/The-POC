// generate-journal-insight — be1, parent-first scope.
// New 2026-08-30, per the guided-journal flow diagram's "LLM process
// insight of overall answers" -> "Display Journal Insight" step. Called
// once, right after the question chain ends (has_cognitive_mechanism came
// back true, or the 3-question hard cap was hit) and BEFORE Preview
// Answer/submit — the parent sees a short "kesimpulan + validasi emosi"
// reflection before deciding to send.
//
// The live response is always in-memory-only for the immediate Preview
// screen, same as evaluate-parent-log-followup. But when `entry_id` is
// given (the entry submit-parent-log-entry already created), this ALSO
// best-effort persists onto parent_log_entries.insight_text so a later
// view of that same entry (DashboardView) shows the same insight instead
// of falling back — found 2026-09-07: entry_id was accepted for exactly
// this since 2026-08-30 but never actually used, so it was always null.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildJournalInsightPrompt,
  JOURNAL_INSIGHT_JSON_SCHEMA,
  type JournalInsightResult,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "liquid/lfm-2.5-2.6b:free";
// Same class as check-log-context's write-path budget — this blocks a
// visible "Lanjut" tap, but needs a bit more room than
// evaluate-parent-log-followup's 5s since it reasons over up to 3 Q&A
// pairs at once, not a single answer.
const TOTAL_BUDGET_MS = 8000;

interface RequestBody {
  child_name: string;
  qa_pairs: { question_text: string; answer_text: string }[];
  entry_id?: string;
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
  if (typeof body.child_name !== "string" || !Array.isArray(body.qa_pairs) || body.qa_pairs.length === 0) {
    return jsonResponse({ error: "child_name and a non-empty qa_pairs array are required" }, 400);
  }

  try {
    const prompt = buildJournalInsightPrompt(
      body.qa_pairs.map((qa) => ({ question: qa.question_text, answer: qa.answer_text })),
      body.child_name,
    );
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_JOURNAL_INSIGHT") ?? DEFAULT_MODEL,
      jsonSchema: JOURNAL_INSIGHT_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 1024,
    }, TOTAL_BUDGET_MS);

    const parsed = parseJsonResponse<JournalInsightResult>(result.text);

    if (body.entry_id) {
      const { error: persistError } = await supabase
        .from("parent_log_entries")
        .update({ insight_text: `${parsed.kesimpulan} ${parsed.validasi_emosi}` })
        .eq("id", body.entry_id);
      // Best-effort — the live response below already carries the insight
      // for the immediate Preview screen regardless of whether this lands.
      if (persistError) {
        console.error("generate-journal-insight: failed to persist insight_text", persistError);
      }
    }

    return jsonResponse({
      kesimpulan: parsed.kesimpulan,
      validasi_emosi: parsed.validasi_emosi,
      provider: result.provider,
    });
  } catch (err) {
    // Fail open, same as evaluate-parent-log-followup: an LLM hiccup here
    // must never block the guided journal from reaching Preview/submit.
    // The client treats a non-200 as "skip the insight screen".
    console.error("generate-journal-insight: generation failed, skipping insight:", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
