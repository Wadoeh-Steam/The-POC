// bridge-parent-log-entry — protective reframe of a parent's guided-journal
// entry for the CHILD to read. Companion to summarize-child-log-entry (the
// other direction), but asymmetric on purpose: that one preserves substance
// faithfully; this one may genuinely soften/reframe harsh judgment, since a
// child reading raw parental judgment is a different harm profile than a
// parent reading a paraphrased child complaint.
//
// Triggered by a DB webhook (20260908000001) when parent_log_entries.
// context_complete flips false->true. Service-role: no end user ever calls
// this directly, same trust model as summarize-child-log-entry.

import { createAdminClient } from "../_shared/supabase-admin.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { callLlmWithFallback, parseJsonResponse } from "../_shared/llm.ts";
import { sendApnsPush } from "../_shared/apns.ts";
import {
  buildParentEntryBridgePrompt,
  PARENT_ENTRY_BRIDGE_JSON_SCHEMA,
  type ParentEntryBridgeResult,
} from "../_shared/prompts.ts";

const DEFAULT_MODEL = "liquid/lfm-2.5-2.6b:free";
// Webhook-triggered, no live user waiting — same budget class as generate-overview.
const TOTAL_BUDGET_MS = 10000;

interface WebhookPayload {
  type: string;
  table: string;
  record: {
    id: string;
    family_id: string;
  };
}

Deno.serve(async (req: Request) => {
  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const entryId = payload.record?.id;
  const familyId = payload.record?.family_id;
  if (!entryId) return jsonResponse({ error: "missing record.id" }, 400);

  const admin = createAdminClient();

  // Best-effort, never blocks the bridge itself on push failures — a child
  // who missed the notification still sees the real content next time they
  // open the app, same fail-open posture as the LLM generation below.
  const notifyChild = async () => {
    if (!familyId) return;
    const { data: childTokens } = await admin
      .from("device_tokens")
      .select("apns_token, profiles!inner(family_id, role)")
      .eq("profiles.family_id", familyId)
      .eq("profiles.role", "child");
    const tokens = (childTokens ?? []).map((t) => t.apns_token);
    if (tokens.length === 0) return;
    const results = await Promise.allSettled(
      tokens.map((token) =>
        sendApnsPush(token, {
          alertTitle: "Jurnal baru dari orang tuamu",
          // Deliberately no content preview — same reason this whole
          // feature exists: a lock-screen notification is a leak surface
          // this session's bridge work was specifically built to close.
          alertBody: "Orang tuamu baru aja nulis jurnal. Yuk buka buat liat.",
          customData: { type: "new_parent_journal", parent_log_entry_id: entryId },
        })
      ),
    );
    const failures = results.filter((r) => r.status === "rejected");
    if (failures.length > 0) console.error("bridge-parent-log-entry: some pushes failed", failures);
  };

  const { data: answers, error: answersError } = await admin
    .from("parent_log_answers")
    .select("question_text, answer_text, sequence")
    .eq("parent_log_entry_id", entryId)
    .order("sequence", { ascending: true });

  if (answersError || !answers || answers.length === 0) {
    // Fail open — the child just keeps seeing the existing generic
    // placeholder (ChildLogDetailView's fallback), same as any other
    // best-effort generation failure in this codebase.
    console.error("bridge-parent-log-entry: no answers found for entry", entryId, answersError);
    return jsonResponse({ ok: false, reason: "no_answers" });
  }

  try {
    const prompt = buildParentEntryBridgePrompt(
      answers.map((a) => ({ question: a.question_text, answer: a.answer_text })),
    );
    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_PARENT_BRIDGE") ?? DEFAULT_MODEL,
      jsonSchema: PARENT_ENTRY_BRIDGE_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 512,
    }, TOTAL_BUDGET_MS);

    const parsed = parseJsonResponse<ParentEntryBridgeResult>(result.text);

    if (parsed.crisis_signal) {
      // Deliberately withheld — leave child_facing_summary NULL rather than
      // let the LLM attempt a delicate rewrite of a genuine safety
      // disclosure. Child keeps seeing the generic placeholder.
      console.warn("bridge-parent-log-entry: crisis_signal true, withholding reframe for entry", entryId);
      return jsonResponse({ ok: true, withheld: true });
    }

    const { error: updateError } = await admin
      .from("parent_log_entries")
      .update({ child_facing_summary: parsed.child_facing_summary })
      .eq("id", entryId);

    if (updateError) {
      console.error("bridge-parent-log-entry: update failed", updateError);
      return jsonResponse({ error: "update_failed" }, 500);
    }

    await notifyChild();

    return jsonResponse({ ok: true });
  } catch (error) {
    // Fail open, same reasoning as the no-answers branch above.
    console.error("bridge-parent-log-entry: generation failed for entry", entryId, error);
    return jsonResponse({ ok: false, reason: "generation_failed" });
  }
});
