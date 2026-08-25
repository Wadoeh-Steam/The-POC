// select-parent-log-questions — be1, parent-first scope.
// Rule-based, NOT an LLM call — Main Prompt 1 is fixed, Main Prompt 2/3 are
// randomized from a pool filtered by the parent's own quick-pick
// (valence/labels), per user decision ("ngikutin emotion picker nya").
// Deliberately cheap/synchronous so this can run before the guided-journal
// UI shows its first screen, no LLM latency/fallback budget involved.
//
// Question bank content below is placeholder copy, not final product
// copy — whoever picks this up should swap in the real question set
// (Figma "Log Input System" mockups) before shipping.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import type { LogContextField } from "../_shared/prompts.ts";

interface QuestionBankEntry {
  field: LogContextField;
  question_text: string;
  // valence_classification values this question fits best; omitted = fits any.
  appliesTo?: string[];
}

const FIXED_MAIN_QUESTION: QuestionBankEntry = {
  field: "FEELING",
  question_text: "Ada hal yang pengen kamu inget dari minggu ini?",
};

const RANDOMIZED_POOL: QuestionBankEntry[] = [
  { field: "TRIGGER", question_text: "Apa yang bikin momen itu berkesan buat kamu?", appliesTo: ["positive", "slightlyPositive"] },
  { field: "PERCEIVED_CAUSE", question_text: "Menurut kamu, kenapa itu bisa kejadian?" },
  { field: "PRIOR_EFFORT", question_text: "Ada yang udah kamu coba lakuin soal itu?" },
  { field: "FUTURE_PLAN", question_text: "Ada rencana buat minggu depan terkait itu?" },
  { field: "EXPECTED_OUTCOME", question_text: "Kamu berharap hasilnya gimana?" },
];

interface RequestBody {
  valence: number;
  valence_classification: string;
  labels: string[];
}

function pickRandomizedQuestions(valenceClassification: string): QuestionBankEntry[] {
  const matching = RANDOMIZED_POOL.filter(
    (q) => !q.appliesTo || q.appliesTo.includes(valenceClassification),
  );
  const pool = matching.length >= 2 ? matching : RANDOMIZED_POOL;
  const shuffled = [...pool].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, 2);
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
  if (typeof body.valence_classification !== "string") {
    return jsonResponse({ error: "valence_classification is required" }, 400);
  }

  const questions = [FIXED_MAIN_QUESTION, ...pickRandomizedQuestions(body.valence_classification)];

  return jsonResponse({
    questions: questions.map((q) => ({ field: q.field, question_text: q.question_text })),
  });
});
