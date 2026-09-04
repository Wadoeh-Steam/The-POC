// generate-reflection — ARCHITECTURE.md §4, §2a. MVP2.
// Same shape as generate-overview — see that function's comments for the
// auth/mode-check reasoning, not repeated here.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildParentOnlyReflectionPrompt,
  buildReflectionPrompt,
  deriveConfidenceTier,
  type EmotionLogForPrompt,
  type LogContextField,
  PARENT_ONLY_REFLECTION_JSON_SCHEMA,
  type ParentInteractionForPrompt,
  type ParentLogEntryForPrompt,
  type ParentOnlyReflectionResult,
  REFLECTION_JSON_SCHEMA,
  type ReflectionResult,
} from "../_shared/prompts.ts";

// Same tier reasoning as generate-overview (free tier, user decision
// 2026-08-14, switched from nemotron-3-super after it failed to complete
// within a reasonable token budget in testing) — see that function's
// comment.
const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";

interface RequestBody {
  family_id: string;
  period_start: string;
  period_end: string;
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
  if (!body.period_start || !body.period_end) {
    return jsonResponse({ error: "period_start and period_end are required" }, 400);
  }

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

  // Rescoped to per-week (was whole-history) so recommendations can
  // actually refresh as new weeks of journaling come in, instead of one
  // cache-forever row per family — same shape as generate-overview.
  // `parent_interactions`/`parent_reflection_logs` are dead (nothing
  // writes to them anymore — see generate-overview's identical fix,
  // root-caused live 2026-09-02): the parent's real journal data source is
  // `parent_log_entries` + `parent_log_answers`. `emotion_logs` (the
  // child's own mood check-ins) stays as-is — a live table, just empty in
  // families with no child profile yet.
  const [{ data: logs }, { data: entries }, { data: childProfile }] = await Promise.all([
    supabase
      .from("emotion_logs")
      .select("id, timestamp, valence, valence_classification, labels, associations, journal, log_context_answers(field, answer)")
      .eq("family_id", body.family_id)
      .eq("context_complete", true)
      .gte("timestamp", body.period_start)
      .lt("timestamp", body.period_end)
      .order("timestamp", { ascending: true })
      .limit(200),
    supabase
      .from("parent_log_entries")
      .select("id, timestamp, valence, labels, associations, insight_text, parent_log_answers(field, question_text, answer_text, sequence)")
      .eq("family_id", body.family_id)
      .gte("timestamp", body.period_start)
      .lt("timestamp", body.period_end)
      .order("timestamp", { ascending: true })
      .limit(50),
    supabase
      .from("profiles")
      .select("display_name")
      .eq("family_id", body.family_id)
      .eq("role", "child")
      .single(),
  ]);

  const logsForPrompt: EmotionLogForPrompt[] = (logs ?? []).map((l) => ({
    timestamp: l.timestamp,
    valence: l.valence,
    valence_classification: l.valence_classification,
    labels: l.labels ?? [],
    associations: l.associations ?? [],
    journal: l.journal,
    context_answers: Object.fromEntries(
      (l.log_context_answers ?? []).map((a: { field: LogContextField; answer: string }) => [a.field, a.answer]),
    ),
  }));

  const journalEntriesForPrompt: ParentLogEntryForPrompt[] = (entries ?? []).map((e) => {
    const answers = (e.parent_log_answers ?? []) as { field: LogContextField; question_text: string; answer_text: string; sequence: number }[];
    return {
      timestamp: e.timestamp,
      isSpecific: answers.length >= 3 && answers.every((a) => a.answer_text.trim().length >= 10),
      answers: answers
        .sort((a, b) => a.sequence - b.sequence)
        .map((a) => ({ field: a.field, questionText: a.question_text, answerText: a.answer_text })),
    };
  });

  // Same interactions shape buildReflectionPrompt already expects — one
  // line per parent_log_entry, using its answers (or insight_text) as the
  // free-text "interaction" description.
  const interactionsForPrompt: ParentInteractionForPrompt[] = (entries ?? []).map((e) => {
    const answers = ((e.parent_log_answers ?? []) as { answer_text: string; sequence: number }[])
      .sort((a, b) => a.sequence - b.sequence);
    return {
      timestamp: e.timestamp,
      topic: (e.associations ?? [])[0] ?? "Umum",
      interaction: answers.length ? answers.map((a) => a.answer_text).join(" ") : (e.insight_text ?? "(tidak ada catatan tambahan)"),
      parent_emotion: (e.labels ?? [])[0] ?? null,
    };
  });

  const hasChild = childProfile != null;
  const parentConfidenceTier = deriveConfidenceTier(
    journalEntriesForPrompt.length,
    journalEntriesForPrompt.filter((e) => e.isSpecific).length,
  );

  try {
    let recommendations: ReflectionResult["recommendations"];
    let promptTokens: number;
    let outputTokens: number;

    if (hasChild) {
      const prompt = buildReflectionPrompt(
        logsForPrompt,
        interactionsForPrompt,
        [],
        childProfile.display_name ?? "anak",
      );

      const result = await callLlmWithFallback(prompt, {
        model: Deno.env.get("OPENROUTER_MODEL_REFLECTION") ?? DEFAULT_MODEL,
        jsonSchema: REFLECTION_JSON_SCHEMA,
        // "/no_think" (llm.ts) — this task specifically had been answering
        // in English despite an explicit Indonesian prompt in earlier
        // testing; with /no_think it stayed correctly Indonesian across the
        // retest, alongside the same latency win as the other three
        // functions (PERFORMANCE_COMPARISON.md §8). Worth continued
        // watching, not proof the language bug is gone for good.
        systemPrompt: "/no_think",
        maxOutputTokens: 6000,
      }, 20000); // user-initiated but not real-time — same budget as generate-overview
      const parsed = parseJsonResponse<ReflectionResult>(result.text);
      recommendations = parsed.recommendations;
      promptTokens = result.promptTokens;
      outputTokens = result.outputTokens;
    } else {
      const prompt = buildParentOnlyReflectionPrompt(journalEntriesForPrompt, parentConfidenceTier);

      const result = await callLlmWithFallback(prompt, {
        model: Deno.env.get("OPENROUTER_MODEL_REFLECTION") ?? DEFAULT_MODEL,
        jsonSchema: PARENT_ONLY_REFLECTION_JSON_SCHEMA,
        systemPrompt: "/no_think",
        maxOutputTokens: 6000,
      }, 20000);
      const parsed = parseJsonResponse<ParentOnlyReflectionResult>(result.text);
      recommendations = parsed.recommendations;
      promptTokens = result.promptTokens;
      outputTokens = result.outputTokens;
    }

    // upsert, not insert: reflections_family_period_idx (unique on
    // family_id+period_start) rejects a second row for the same
    // family/week outright — same race/exact-match-miss reasoning as
    // generate-overview's identical upsert switch.
    const { data: inserted, error: insertError } = await supabase
      .from("reflections")
      .upsert({
        family_id: body.family_id,
        period_start: body.period_start,
        period_end: body.period_end,
        recommendations,
        raw_response: { promptTokens, outputTokens },
      }, { onConflict: "family_id,period_start" })
      .select()
      .single();

    if (insertError) {
      console.error("generate-reflection: upsert failed", insertError);
      return jsonResponse({ error: "insert_failed" }, 500);
    }

    return jsonResponse(inserted);
  } catch (err) {
    console.error("generate-reflection: generation failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
