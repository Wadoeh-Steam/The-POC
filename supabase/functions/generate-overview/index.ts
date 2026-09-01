// generate-overview — ARCHITECTURE.md §4, §2a.
// Client call, POST { family_id }. Only invoked when the PARENT's own
// llm_mode = server (the parent initiates this, so their setting governs
// it — §2a's per-profile rule). Uses the user-scoped client (not admin)
// for every read: RLS already enforces "parent role, own family" for
// everything this needs, no reason to bypass it here.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildOverviewPrompt,
  deriveConfidenceTier,
  type EmotionLogForPrompt,
  type LogContextField,
  OVERVIEW_JSON_SCHEMA,
  type OverviewResult,
  type ParentInteractionForPrompt,
  type ParentLogEntryForPrompt,
  type ParentReflectionForPrompt,
} from "../_shared/prompts.ts";

// This is the product's actual differentiator (per PERFORMANCE_COMPARISON.md
// — the misalignment-catching key_insight is the standout value vs.
// on-device). User decision (2026-08-14): free-tier OpenRouter model.
// The larger `nemotron-3-super-120b` was tried first on a raw-capacity
// theory, but empirically burns its whole token budget on chain-of-thought
// reasoning before reaching the answer (hit finish_reason=length at both
// 100 and 512 max_tokens in testing) — switched to the smaller model that
// was actually confirmed to complete. Unverified against paid alternatives
// on actual insight quality — worth A/B testing with the same
// benchmark-harness approach Phase 0 used — see ADR-0010.
const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";

interface RequestBody {
  family_id: string;
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

  const [{ data: logs }, { data: interactions }, { data: reflections }, { data: journalEntries }, { data: childProfile }] =
    await Promise.all([
      supabase
        .from("emotion_logs")
        .select("id, timestamp, valence, valence_classification, labels, associations, journal, log_context_answers(field, answer)")
        .eq("family_id", body.family_id)
        .eq("context_complete", true)
        .order("timestamp", { ascending: true })
        .limit(50),
      supabase
        .from("parent_interactions")
        .select("timestamp, topic, interaction, parent_emotion")
        .eq("family_id", body.family_id)
        .order("timestamp", { ascending: true })
        .limit(20),
      supabase
        .from("parent_reflection_logs")
        .select("timestamp, emotion, note")
        .eq("family_id", body.family_id)
        .order("timestamp", { ascending: true })
        .limit(20),
      supabase
        .from("parent_log_entries")
        .select("timestamp, parent_log_answers(field, question_text, answer_text, sequence)")
        .eq("family_id", body.family_id)
        .eq("context_complete", true)
        .order("timestamp", { ascending: true })
        .limit(20),
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

  // TODO: isSpecific is placeholder-false for child logs / parent
  // interactions/reflections — nothing computes has_cognitive_mechanism for
  // those yet. Fails safe: they read as [general], which the prompt's own
  // rules already treat as a weak signal.
  const taggedLogs = logsForPrompt.map((log) => ({ log, isSpecific: false }));
  const taggedInteractions = ((interactions ?? []) as ParentInteractionForPrompt[]).map((interaction) => ({
    interaction,
    isSpecific: false,
  }));
  const taggedReflections = ((reflections ?? []) as ParentReflectionForPrompt[]).map((reflection) => ({
    reflection,
    isSpecific: false,
  }));

  // Guided-journal entries DO have a real signal: evaluate-parent-log-followup
  // only stops the chain early (fewer than the 3-question hard cap) when it
  // detected a cognitive mechanism, so an entry with < 3 answers is a good
  // proxy for "spesifik" without needing another LLM call here.
  const journalEntriesForPrompt: ParentLogEntryForPrompt[] = (journalEntries ?? []).map((e) => {
    const answers = (e.parent_log_answers ?? []) as { field: LogContextField; question_text: string; answer_text: string; sequence: number }[];
    return {
      timestamp: e.timestamp,
      isSpecific: answers.length < 3,
      answers: answers
        .sort((a, b) => a.sequence - b.sequence)
        .map((a) => ({ field: a.field, questionText: a.question_text, answerText: a.answer_text })),
    };
  });

  const childConfidenceTier = deriveConfidenceTier(taggedLogs.length, 0);
  const parentConfidenceTier = deriveConfidenceTier(
    taggedInteractions.length + taggedReflections.length + journalEntriesForPrompt.length,
    journalEntriesForPrompt.filter((e) => e.isSpecific).length,
  );

  try {
    const prompt = buildOverviewPrompt(
      taggedLogs,
      taggedInteractions,
      taggedReflections,
      journalEntriesForPrompt,
      childProfile?.display_name ?? "anak",
      childConfidenceTier,
      parentConfidenceTier,
    );

    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_OVERVIEW") ?? DEFAULT_MODEL,
      jsonSchema: OVERVIEW_JSON_SCHEMA,
      // "/no_think" (llm.ts) — cut ~20s to ~7s in testing
      // (PERFORMANCE_COMPARISON.md §8), quality looked comparable on the
      // dummy dataset (still needs the real A/B harness work in ADR-0010's
      // Action Items, this was a smoke test not a rigorous eval).
      systemPrompt: "/no_think",
      maxOutputTokens: 6000,
    }, 20000); // more generous than followup-eval's 5s — this isn't a real-time UX path
    const parsed = parseJsonResponse<OverviewResult>(result.text);

    const { data: inserted, error: insertError } = await supabase
      .from("overviews")
      .insert({
        family_id: body.family_id,
        headline: parsed.overview.headline,
        summary: parsed.overview.summary,
        patterns: parsed.overview.patterns,
        relationship_signal: parsed.overview.relationship_signal,
        communication_style: parsed.overview.communication_style,
        data_confidence: parsed.overview.data_confidence,
        key_insight: parsed.overview.key_insight,
        raw_response: { promptTokens: result.promptTokens, outputTokens: result.outputTokens },
      })
      .select()
      .single();

    if (insertError) {
      console.error("generate-overview: insert failed", insertError);
      return jsonResponse({ error: "insert_failed" }, 500);
    }

    return jsonResponse(inserted);
  } catch (err) {
    console.error("generate-overview: generation failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
