// submit-parent-log-entry — be1, parent-first scope.
// Called once, at the end of the guided-journal flow (after the Preview
// Answer page's "Send"), with every main + followup answer collected
// client-side. Mirrors §3a's emotion_logs pattern: insert incomplete first,
// write answers, then flip context_complete — not a single atomic
// transaction (PostgREST/Edge Function has no cross-table transaction
// primitive here, same constraint the rest of this codebase lives with),
// but structured so a failure mid-way leaves an honestly-incomplete row
// rather than a complete row with missing answers.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import type { LogContextField } from "../_shared/prompts.ts";

interface AnswerInput {
  field: LogContextField;
  source: "main" | "followup";
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

  // Belt-and-suspenders on top of RLS, same pattern as generate-overview —
  // gives a clear 403 instead of RLS just silently returning nothing.
  const { data: callerProfile } = await supabase
    .from("profiles")
    .select("role, family_id")
    .eq("id", user.id)
    .single();
  if (!callerProfile || callerProfile.role !== "parent" || callerProfile.family_id !== body.family_id) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const { data: entry, error: entryError } = await supabase
    .from("parent_log_entries")
    .insert({
      family_id: body.family_id,
      parent_id: user.id,
      valence: body.valence,
      labels: body.labels ?? [],
      associations: body.associations ?? [],
      context_complete: false,
    })
    .select()
    .single();

  if (entryError || !entry) {
    console.error("submit-parent-log-entry: entry insert failed", entryError);
    return jsonResponse({ error: "insert_failed" }, 500);
  }

  const { error: answersError } = await supabase
    .from("parent_log_answers")
    .insert(
      body.answers.map((a) => ({
        parent_log_entry_id: entry.id,
        field: a.field,
        source: a.source,
        question_text: a.question_text,
        answer_text: a.answer_text,
      })),
    );

  if (answersError) {
    // Entry row stays with context_complete = false — honest partial
    // state, matches §3a's own "incomplete row" precedent rather than
    // silently reporting success.
    console.error("submit-parent-log-entry: answers insert failed", answersError);
    return jsonResponse({ error: "answers_insert_failed", parent_log_entry_id: entry.id }, 500);
  }

  const { error: completeError } = await supabase
    .from("parent_log_entries")
    .update({ context_complete: true })
    .eq("id", entry.id);

  if (completeError) {
    console.error("submit-parent-log-entry: context_complete update failed", completeError);
    return jsonResponse({ error: "complete_update_failed", parent_log_entry_id: entry.id }, 500);
  }

  return jsonResponse({ parent_log_entry_id: entry.id });
});
