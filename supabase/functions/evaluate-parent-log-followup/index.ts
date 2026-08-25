// evaluate-parent-log-followup — be1, parent-first scope.
// Called per main-question view, in real time, while the parent is still
// on that screen — sits in the write path, same latency sensitivity as
// check-log-context (§3a). Uses callLlmWithFallback (OpenRouter -> Requesty
// -> Gemini) with a short total budget: if the whole chain can't answer in
// time, we skip the followup rather than block the UI — per user decision,
// "kalau timeout, skip aja".
//
// Trigger mechanism is deliberately NOT check-log-context's LogContextField
// extraction — see prompts.ts's buildFollowupEvaluationPrompt. Does not
// write to the database; the client holds all answers in memory until
// submit-parent-log-entry (per user decision: app kill = full reset, no
// partial persistence).

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildFollowupEvaluationPrompt,
  FOLLOWUP_EVALUATION_JSON_SCHEMA,
  type FollowupEvaluationResult,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";
// Total wall-clock budget across the WHOLE OpenRouter->Requesty->Gemini
// chain, not per-provider — see callLlmWithFallback's doc comment. Tighter
// than generate-overview's tolerance since this blocks a visible UI step.
const TOTAL_BUDGET_MS = 5000;

interface RequestBody {
  question_text: string;
  answer_text: string;
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
  if (!body.question_text || !body.answer_text) {
    return jsonResponse({ error: "question_text and answer_text are required" }, 400);
  }

  try {
    const prompt = buildFollowupEvaluationPrompt(body.question_text, body.answer_text);
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_FOLLOWUP_EVAL") ?? DEFAULT_MODEL,
      jsonSchema: FOLLOWUP_EVALUATION_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 1024,
    }, TOTAL_BUDGET_MS);

    const parsed = parseJsonResponse<FollowupEvaluationResult>(result.text);

    return jsonResponse({
      has_cognitive_mechanism: parsed.has_cognitive_mechanism === true,
      followup_question: parsed.has_cognitive_mechanism === true ? null : parsed.followup_question,
      // Kept for schema consistency; downstream crisis_events handling is
      // backlogged on this path (see context.md) — accepted and returned,
      // not acted on.
      crisis_signal: parsed.crisis_signal === true,
      skipped: false,
      provider: result.provider,
    });
  } catch (err) {
    // Timeout / all-providers-failed / malformed JSON all land here.
    // Per user decision: skip the followup, never block the user on an
    // LLM hiccup — this is a 200, not an error response, since "no
    // followup" is a valid, expected outcome from the client's perspective.
    console.error("evaluate-parent-log-followup: evaluation failed, skipping followup:", err);
    return jsonResponse({
      has_cognitive_mechanism: true,
      followup_question: null,
      crisis_signal: false,
      skipped: true,
    });
  }
});
