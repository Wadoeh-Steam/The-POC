// generate-reflection — ARCHITECTURE.md §4, §2a. MVP2.
// Same shape as generate-overview — see that function's comments for the
// auth/mode-check reasoning, not repeated here.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlm, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildReflectionPrompt,
  type EmotionLogForPrompt,
  type LogContextField,
  type ParentInteractionForPrompt,
  type ParentReflectionForPrompt,
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

  // Full history for reflections (vs. generate-overview's recency-limited
  // read) — recommendations are meant to be based on the whole picture.
  const [{ data: logs }, { data: interactions }, { data: reflectionsCtx }, { data: childProfile }] = await Promise.all([
    supabase
      .from("emotion_logs")
      .select("id, timestamp, valence, valence_classification, labels, associations, journal, log_context_answers(field, answer)")
      .eq("family_id", body.family_id)
      .eq("context_complete", true)
      .order("timestamp", { ascending: true })
      .limit(200),
    supabase
      .from("parent_interactions")
      .select("timestamp, topic, interaction, parent_emotion")
      .eq("family_id", body.family_id)
      .order("timestamp", { ascending: true })
      .limit(50),
    supabase
      .from("parent_reflection_logs")
      .select("timestamp, emotion, note")
      .eq("family_id", body.family_id)
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

  try {
    const prompt = buildReflectionPrompt(
      logsForPrompt,
      (interactions ?? []) as ParentInteractionForPrompt[],
      (reflectionsCtx ?? []) as ParentReflectionForPrompt[],
      childProfile?.display_name ?? "anak",
    );

    const result = await callLlm(prompt, {
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
    });
    const parsed = parseJsonResponse<ReflectionResult>(result.text);

    const { data: inserted, error: insertError } = await supabase
      .from("reflections")
      .insert({
        family_id: body.family_id,
        recommendations: parsed.recommendations,
        raw_response: { promptTokens: result.promptTokens, outputTokens: result.outputTokens },
      })
      .select()
      .single();

    if (insertError) {
      console.error("generate-reflection: insert failed", insertError);
      return jsonResponse({ error: "insert_failed" }, 500);
    }

    return jsonResponse(inserted);
  } catch (err) {
    console.error("generate-reflection: generation failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
