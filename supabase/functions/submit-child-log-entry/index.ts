// submit-child-log-entry — child-side mirror of submit-parent-log-entry.
// Writes emotion_logs + log_context_answers, insert-incomplete-then-flip
// same as the parent path. context_complete=true fires generate-how-to-react
// and summarize-child-log-entry (DB webhooks).

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import type { LogContextField } from "../_shared/prompts.ts";

interface AnswerInput {
  field: LogContextField;
  source: "main" | "followup";
  sequence: number;
  question_text: string;
  answer_text: string;
}

interface RequestBody {
  family_id: string;
  valence: number;
  labels: string[];
  associations: string[];
  answers: AnswerInput[];
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
  if (!body.family_id || typeof body.valence !== "number" || !Array.isArray(body.answers) || body.answers.length === 0) {
    return jsonResponse({ error: "family_id, valence and a non-empty answers array are required" }, 400);
  }

  // Belt-and-suspenders on top of RLS (same pattern as submit-parent-log-entry):
  // clear 403 instead of RLS silently returning nothing.
  //
  // No longer checking child_consent_at here: the consent screen that was
  // meant to set it (ConsentGateView) was disabled client-side in
  // ios-client@b8a35ff (ChildRootView routes straight past it now), so no
  // reachable code path could ever set child_consent_at — this check and
  // the matching emotion_logs_insert_child RLS clause (dropped in
  // 20260909000003) were permanently blocking every child account created
  // since. Re-add both together if the consent screen ever comes back.
  const { data: callerProfile } = await supabase
    .from("profiles")
    .select("role, family_id")
    .eq("id", user.id)
    .single();

  if (
    !callerProfile ||
    callerProfile.role !== "child" ||
    callerProfile.family_id.toLowerCase() !== body.family_id.toLowerCase()
  ) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const { data: entry, error: entryError } = await supabase
    .from("emotion_logs")
    .insert({
      child_id: user.id,
      family_id: body.family_id,
      kind: "dailyMood",
      valence: body.valence,
      labels: body.labels ?? [],
      associations: body.associations ?? [],
      context_complete: false,
    })
    .select()
    .single();

  if (entryError || !entry) {
    console.error("submit-child-log-entry: entry insert failed", entryError);
    return jsonResponse({ error: "insert_failed" }, 500);
  }

  const { error: answersError } = await supabase
    .from("log_context_answers")
    .insert(
      body.answers.map((a) => ({
        emotion_log_id: entry.id,
        field: a.field,
        answer: a.answer_text,
        question_text: a.question_text,
        source: "manual",
        sequence: a.sequence,
      })),
    );

  if (answersError) {
    // Entry row stays with context_complete = false — same honest-partial
    // precedent as submit-parent-log-entry / §3a's crisis-early-save case.
    console.error("submit-child-log-entry: answers insert failed", answersError);
    return jsonResponse({ error: "answers_insert_failed", emotion_log_id: entry.id }, 500);
  }

  const { error: completeError } = await supabase
    .from("emotion_logs")
    .update({ context_complete: true })
    .eq("id", entry.id);

  if (completeError) {
    console.error("submit-child-log-entry: context_complete update failed", completeError);
    return jsonResponse({ error: "complete_update_failed", emotion_log_id: entry.id }, 500);
  }

  return jsonResponse({ emotion_log_id: entry.id });
});
