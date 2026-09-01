// generate-how-to-react — ARCHITECTURE.md §2a, §4.
// DB webhook on emotion_logs INSERT, fired only when context_complete =
// true (enforced by the trigger's WHEN clause, see
// supabase/migrations/20260814000003_webhooks.sql).
//
// Checks the CHILD's own llm_mode first — no-ops if on_device, since in
// that mode the child's app already computed and wrote the tip itself in
// the same submission. This is the belt half of "belt and suspenders":
// the trigger only fires on context_complete, but mode-correctness is
// re-checked here too, not assumed from the fact that this function ran.

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback } from "../_shared/llm.ts";
import {
  buildHowToReactPrompt,
  type EmotionLogForPrompt,
  type LogContextField,
} from "../_shared/prompts.ts";

// User decision (2026-08-14): free-tier OpenRouter model. `google/gemma-4-
// 26b-a4b-it:free` was the original pick for tone reasons, but hit a 429
// on OpenRouter's shared free-tier pool during testing (not this app's own
// usage — congestion from other free users) — switched to the one free
// model that was empirically confirmed working end-to-end, same as
// check-log-context. It's a reasoning model too — see that function's
// comment for the latency trade-off, which applies here as well, just
// less critically since this call isn't on the write-path itself.
const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";

interface WebhookPayload {
  type: string;
  table: string;
  record: {
    id: string;
    child_id: string;
    "timestamp": string;
    valence: number;
    valence_classification: string;
    labels: string[];
    associations: string[];
    journal: string | null;
    context_complete: boolean;
  };
}

Deno.serve(async (req: Request) => {
  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const record = payload.record;
  if (!record?.context_complete) {
    // Should never happen given the trigger's WHEN clause, but don't trust
    // that alone — see the belt-and-suspenders note above.
    return jsonResponse({ skipped: "context_not_complete" });
  }

  const supabase = createAdminClient();

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("llm_mode, display_name")
    .eq("id", record.child_id)
    .single();

  if (profileError || !profile) {
    console.error("generate-how-to-react: could not load child profile", profileError);
    return jsonResponse({ error: "profile_lookup_failed" }, 500);
  }

  if (profile.llm_mode === "on_device") {
    // Child's device already wrote how_to_react_tips itself. See §2a.
    return jsonResponse({ skipped: "on_device_mode" });
  }

  const { data: answers } = await supabase
    .from("log_context_answers")
    .select("field, answer")
    .eq("emotion_log_id", record.id);

  const contextAnswers = Object.fromEntries(
    (answers ?? []).map((a) => [a.field as LogContextField, a.answer]),
  ) as Partial<Record<LogContextField, string>>;

  const logForPrompt: EmotionLogForPrompt = {
    timestamp: record.timestamp,
    valence: record.valence,
    valence_classification: record.valence_classification,
    labels: record.labels ?? [],
    associations: record.associations ?? [],
    journal: record.journal,
    context_answers: contextAnswers,
  };

  try {
    const result = await callLlmWithFallback(buildHowToReactPrompt(logForPrompt, profile.display_name), {
      model: Deno.env.get("OPENROUTER_MODEL_HOW_TO_REACT") ?? DEFAULT_MODEL,
      // "/no_think" (llm.ts) — see check-log-context's comment. Testing
      // (PERFORMANCE_COMPARISON.md §8) also fixed an unrelated bug this
      // call didn't have but generate-reflection did: language-consistency
      // (some responses ignoring the Indonesian instruction) improved too,
      // not just latency.
      systemPrompt: "/no_think",
      maxOutputTokens: 3000,
    }, 20000); // webhook-triggered, no live user waiting — same budget as generate-overview

    const { error: insertError } = await supabase.from("how_to_react_tips").insert({
      emotion_log_id: record.id,
      tip: result.text.trim(),
      raw_response: { promptTokens: result.promptTokens, outputTokens: result.outputTokens },
    });

    if (insertError) {
      console.error("generate-how-to-react: insert failed", insertError);
      return jsonResponse({ error: "insert_failed" }, 500);
    }

    return jsonResponse({ ok: true });
  } catch (err) {
    console.error("generate-how-to-react: Gemini call failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
