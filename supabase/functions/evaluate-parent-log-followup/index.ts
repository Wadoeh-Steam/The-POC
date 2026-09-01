// evaluate-parent-log-followup — be1, parent-first scope.
// Called per question view, in real time, while the parent is still on
// that screen — sits in the write path, same latency sensitivity as
// check-log-context (§3a). Always generates a follow-up (fixed 3-question
// arc: anchor + 2 follow-ups) — see prompts.ts's buildFollowupEvaluationPrompt
// for why this isn't gated on a "shallow vs deep" classification anymore.
// Does not write to the database; the client holds all answers in memory
// until submit-parent-log-entry.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildFollowupEvaluationPrompt,
  FOLLOWUP_EVALUATION_JSON_SCHEMA,
  type FollowupEvaluationResult,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";
const TOTAL_BUDGET_MS = 5000;

// Used only if the LLM chain fails outright — keeps the 3-question arc
// intact (a generic follow-up beats silently dropping to 2 questions),
// matching the stage-specific examples already in the prompt.
const FALLBACK_QUESTION: Record<1 | 2, { affirmation: string; followup_question: string }> = {
  1: {
    affirmation: "Makasih udah cerita ya.",
    followup_question: "Kira-kira kenapa kamu ngerasa begitu?",
  },
  2: {
    affirmation: "Oke, makasih udah cerita lebih jauh.",
    followup_question: "Ada yang pengen kamu coba beda abis ini?",
  },
};

interface RequestBody {
  question_text: string;
  answer_text: string;
  followup_number: 1 | 2;
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
  if (!body.question_text || !body.answer_text || (body.followup_number !== 1 && body.followup_number !== 2)) {
    return jsonResponse({ error: "question_text, answer_text and followup_number (1 or 2) are required" }, 400);
  }

  try {
    const prompt = buildFollowupEvaluationPrompt(body.question_text, body.answer_text, body.followup_number);
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_FOLLOWUP_EVAL") ?? DEFAULT_MODEL,
      jsonSchema: FOLLOWUP_EVALUATION_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 1024,
    }, TOTAL_BUDGET_MS);

    const parsed = parseJsonResponse<FollowupEvaluationResult>(result.text);

    return jsonResponse({
      affirmation: parsed.affirmation,
      followup_question: parsed.followup_question,
      // Kept for schema consistency; downstream crisis_events handling is
      // backlogged on this path (see context.md) — accepted and returned,
      // not acted on.
      crisis_signal: parsed.crisis_signal === true,
      skipped: false,
      provider: result.provider,
    });
  } catch (err) {
    console.error("evaluate-parent-log-followup: generation failed, using fallback question:", err);
    return jsonResponse({
      ...FALLBACK_QUESTION[body.followup_number],
      crisis_signal: false,
      skipped: true,
    });
  }
});
