// generate-child-log-insight — child-side mirror of generate-journal-insight.
// Called once, right after the child's guided-journal chain ends and before
// submit, over the same Q&A pairs collected client-side. Addressed directly
// to the child ("kamu"), not paraphrased about them (that's
// summarize-child-log-entry's parent_facing_summary, a separate output for
// generate-overview).
//
// When `entry_id` is given (the emotion_log this submission created),
// ALSO best-effort persists onto emotion_logs.child_insight_text so a
// later view of that same entry (ChildLogDetailView) shows the same
// insight instead of always falling back. emotion_logs has no UPDATE RLS
// policy (append-only by design, see 20260814000002_rls_policies.sql), so
// this uses the admin client and manually checks the entry belongs to the
// caller first — RLS isn't there to do it for us on this table.

import { createAdminClient, createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildChildJournalInsightPrompt,
  CHILD_JOURNAL_INSIGHT_JSON_SCHEMA,
  type JournalInsightResult,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "liquid/lfm-2.5-2.6b:free";
// Same budget class as generate-journal-insight — blocks a visible "Lanjut"
// tap, reasons over up to 3 Q&A pairs at once.
const TOTAL_BUDGET_MS = 8000;

interface RequestBody {
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
  if (!Array.isArray(body.qa_pairs) || body.qa_pairs.length === 0) {
    return jsonResponse({ error: "a non-empty qa_pairs array is required" }, 400);
  }

  try {
    const prompt = buildChildJournalInsightPrompt(
      body.qa_pairs.map((qa) => ({ question: qa.question_text, answer: qa.answer_text })),
    );
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_CHILD_JOURNAL_INSIGHT") ?? DEFAULT_MODEL,
      jsonSchema: CHILD_JOURNAL_INSIGHT_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 1024,
    }, TOTAL_BUDGET_MS);

    const parsed = parseJsonResponse<JournalInsightResult>(result.text);

    if (body.entry_id) {
      const admin = createAdminClient();
      const { data: entry, error: lookupError } = await admin
        .from("emotion_logs")
        .select("id, child_id")
        .eq("id", body.entry_id)
        .single();

      if (lookupError || !entry || entry.child_id !== user.id) {
        console.error("generate-child-log-insight: entry_id ownership check failed, skipping persist", lookupError);
      } else {
        const { error: persistError } = await admin
          .from("emotion_logs")
          .update({ child_insight_text: `${parsed.kesimpulan} ${parsed.validasi_emosi}` })
          .eq("id", body.entry_id);
        // Best-effort — the live response below already carries the insight
        // for the immediate Preview screen regardless of whether this lands.
        if (persistError) {
          console.error("generate-child-log-insight: failed to persist child_insight_text", persistError);
        }
      }
    }

    return jsonResponse({
      kesimpulan: parsed.kesimpulan,
      validasi_emosi: parsed.validasi_emosi,
      provider: result.provider,
    });
  } catch (err) {
    // Fail open, same as generate-journal-insight: an LLM hiccup here must
    // never block the guided journal from reaching Preview/submit.
    console.error("generate-child-log-insight: generation failed, skipping insight:", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
