// summarize-child-log-entry — DB webhook on emotion_logs INSERT
// (context_complete = true), alongside generate-how-to-react's webhook.
// Writes parent_facing_summary — the only thing generate-overview is
// allowed to read for the child signal. No on-device path; always server.

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import {
  buildChildEntryParaphrasePrompt,
  type ChildEntryParaphraseResult,
  CHILD_ENTRY_PARAPHRASE_JSON_SCHEMA,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "nvidia/nemotron-nano-9b-v2:free";

interface WebhookPayload {
  type: string;
  table: string;
  record: {
    id: string;
    child_id: string;
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
    return jsonResponse({ skipped: "context_not_complete" });
  }

  const supabase = createAdminClient();

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("display_name")
    .eq("id", record.child_id)
    .single();

  if (profileError || !profile) {
    console.error("summarize-child-log-entry: could not load child profile", profileError);
    return jsonResponse({ error: "profile_lookup_failed" }, 500);
  }

  const { data: answers, error: answersError } = await supabase
    .from("log_context_answers")
    .select("question_text, answer")
    .eq("emotion_log_id", record.id)
    .order("sequence", { ascending: true });

  if (answersError || !answers || answers.length === 0) {
    console.error("summarize-child-log-entry: could not load answers", answersError);
    return jsonResponse({ error: "answers_lookup_failed" }, 500);
  }

  try {
    const prompt = buildChildEntryParaphrasePrompt(
      answers.map((a) => ({ question: a.question_text ?? "", answer: a.answer })),
      profile.display_name,
    );
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_CHILD_PARAPHRASE") ?? DEFAULT_MODEL,
      jsonSchema: CHILD_ENTRY_PARAPHRASE_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 1500,
    }, 20000); // webhook-triggered, no live user waiting — same budget class as generate-how-to-react

    const parsed = parseJsonResponse<ChildEntryParaphraseResult>(result.text);

    const { error: updateError } = await supabase
      .from("emotion_logs")
      .update({ parent_facing_summary: parsed.parent_facing_summary })
      .eq("id", record.id);

    if (updateError) {
      console.error("summarize-child-log-entry: update failed", updateError);
      return jsonResponse({ error: "update_failed" }, 500);
    }

    return jsonResponse({ ok: true });
  } catch (err) {
    // Fail open — generate-overview simply won't have this entry's paraphrase yet.
    console.error("summarize-child-log-entry: generation failed", err);
    return jsonResponse({ error: "generation_failed" }, 502);
  }
});
