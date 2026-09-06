// Core generation logic shared by generate-overview (per-request, called by
// a signed-in parent) and generate-weekly-overviews-batch (server-
// triggered, one Supabase client acting across every family) — split out
// 2026-09-07 so the Friday-night cron doesn't duplicate this logic. Neither
// caller's authorization/authentication happens in here: this assumes the
// caller has already established it's allowed to generate for `familyId`.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { callLlmWithFallback, parseJsonResponse } from "./llm.ts";
import {
  buildOverviewPrompt,
  buildParentOnlyOverviewPrompt,
  type ChildProfileForPrompt,
  deriveConfidenceTier,
  type EmotionLogForPrompt,
  type LogContextField,
  OVERVIEW_JSON_SCHEMA,
  type OverviewResult,
  PARENT_ONLY_OVERVIEW_JSON_SCHEMA,
  type ParentInteractionForPrompt,
  type ParentLogEntryForPrompt,
  type ParentOnlyOverviewResult,
  type ParentReflectionForPrompt,
} from "./prompts.ts";

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

type Pattern = { topic: string; observation: string; suggested_approach: string };

// The model classifies each observation into one of 4 topic buckets
// (Pendidikan|Pertemanan|Keluarga|Lainnya) independently per pattern, so
// two genuinely distinct observations that happen to land in the same
// bucket come back as two separate pattern entries — e.g. two different
// school-related moments both tagged "Pendidikan". The client renders one
// card per array entry with the topic as its header, so that read as two
// identical-looking cards. Merge same-topic entries into one card here
// (observations concatenated so neither is lost; suggested_approach kept
// to the first one only — WILL/OPTIONS in the prompt already picks that
// down to a single concrete step, concatenating two would turn it back
// into a list). Root-caused live 2026-09-03 against Radit dev's real
// generated overview (2 separate "Pendidikan" patterns).
function mergePatternsByTopic(patterns: Pattern[]): Pattern[] {
  const order: string[] = [];
  const byTopic = new Map<string, Pattern[]>();

  for (const p of patterns) {
    if (!byTopic.has(p.topic)) {
      order.push(p.topic);
      byTopic.set(p.topic, []);
    }
    byTopic.get(p.topic)!.push(p);
  }

  return order.map((topic) => {
    const group = byTopic.get(topic)!;
    return {
      topic,
      observation: group.map((p) => p.observation).join(" "),
      suggested_approach: group[0].suggested_approach,
    };
  });
}

export async function generateOverviewCore(
  supabase: SupabaseClient,
  // deno-lint-ignore no-explicit-any
  familyId: any,
  periodStart: string | null,
  periodEnd: string | null,
) {
  const [{ data: logs }, { data: interactions }, { data: reflections }, { data: journalEntries }, { data: childProfile }, { data: childProfiles }] =
    await Promise.all([
      supabase
        .from("emotion_logs")
        .select("id, timestamp, valence, valence_classification, labels, associations, journal, log_context_answers(field, answer)")
        .eq("family_id", familyId)
        .eq("context_complete", true)
        .order("timestamp", { ascending: true })
        .limit(50),
      supabase
        .from("parent_interactions")
        .select("timestamp, topic, interaction, parent_emotion")
        .eq("family_id", familyId)
        .order("timestamp", { ascending: true })
        .limit(20),
      supabase
        .from("parent_reflection_logs")
        .select("timestamp, emotion, note")
        .eq("family_id", familyId)
        .order("timestamp", { ascending: true })
        .limit(20),
      supabase
        .from("parent_log_entries")
        .select("timestamp, child_profile_id, parent_log_answers(field, question_text, answer_text, sequence)")
        .eq("family_id", familyId)
        .eq("context_complete", true)
        .order("timestamp", { ascending: true })
        .limit(20),
      supabase
        .from("profiles")
        .select("display_name")
        .eq("family_id", familyId)
        .eq("role", "child")
        .single(),
      // Standalone, parent-authored child records (multi-child support,
      // 2026-09-07) — unrelated to the profiles.role='child' lookup above,
      // which is about a real connected child account. Full profile (not
      // just nickname) as of 2026-09-07: friction_areas/communication_
      // style feed formatChildRosterForPrompt so a "[tentang jkw]"-tagged
      // entry can be commented on with the actual onboarding context, not
      // just the entry's own text — detection itself already happened,
      // once, in generate-journal-insight; this is purely for richer
      // commentary on entries already tagged.
      supabase
        .from("child_profiles")
        .select("id, nickname, friction_areas, communication_style")
        .eq("family_id", familyId),
    ]);

  const childNicknameById = new Map((childProfiles ?? []).map((c) => [c.id, c.nickname]));
  const childProfilesForPrompt: ChildProfileForPrompt[] = (childProfiles ?? []).map((c) => ({
    id: c.id,
    nickname: c.nickname,
    frictionAreas: c.friction_areas ?? [],
    communicationStyle: c.communication_style ?? [],
  }));

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

  // 2026-09-03: was `answers.length < 3` — a proxy for "the chain stopped
  // early because evaluate-parent-log-followup detected a cognitive
  // mechanism". That gate was removed 2026-09-01 (see
  // followupStageInstruction's comment in prompts.ts) — the chain is now
  // ALWAYS the full 3-question arc, so every real entry has exactly 3
  // answers and the old proxy was permanently false. That silently forced
  // specificRatio to 0 and data_confidence to "low" on every call
  // regardless of how substantive the answers actually were, which made
  // the prompt's own (correct) "low confidence -> keep patterns empty"
  // rule fire every time — found live 2026-09-03 (patterns[] stayed empty
  // against a real account with 13 detailed multi-topic entries this
  // week). The forced 3-question depth is now guaranteed structurally, so
  // treat length as a sanity floor instead: specific means the parent
  // actually completed the full arc with non-trivial answers, not cut
  // short (e.g. by the confirmation-alert bug that used to end a chain
  // after 1-2 answers) or left blank.
  const journalEntriesForPrompt: ParentLogEntryForPrompt[] = (journalEntries ?? []).map((e) => {
    const answers = (e.parent_log_answers ?? []) as { field: LogContextField; question_text: string; answer_text: string; sequence: number }[];
    return {
      timestamp: e.timestamp,
      isSpecific: answers.length >= 3 && answers.every((a) => a.answer_text.trim().length >= 10),
      answers: answers
        .sort((a, b) => a.sequence - b.sequence)
        .map((a) => ({ field: a.field, questionText: a.question_text, answerText: a.answer_text })),
      childNickname: e.child_profile_id ? childNicknameById.get(e.child_profile_id) ?? null : null,
    };
  });

  const childConfidenceTier = deriveConfidenceTier(taggedLogs.length, 0);
  const parentConfidenceTier = deriveConfidenceTier(
    taggedInteractions.length + taggedReflections.length + journalEntriesForPrompt.length,
    journalEntriesForPrompt.filter((e) => e.isSpecific).length,
  );

  // No child profile in the family yet (solo mode, ARCHITECTURE.md §3b) —
  // buildOverviewPrompt assumes there's real child-side data to weigh
  // against the parent's, and only hedges via data_confidence; it was
  // never designed to run on zero child data at all, and its
  // relationship_signal/child_openness fields have no real basis to stand
  // on in that case. buildParentOnlyOverviewPrompt (§6 of prompts.ts) was
  // written for exactly this — parent's own guided-journal entries only,
  // with an explicit rule to never assert the child's feelings as fact —
  // but had no caller until now. Wired in live 2026-09-02.
  const hasChild = childProfile != null;

  let overviewFields: {
    headline: string;
    summary: string;
    patterns: unknown;
    relationship_signal: unknown;
    communication_style: unknown;
    data_confidence: unknown;
    key_insight: string;
  };
  let promptTokens: number;
  let outputTokens: number;

  if (hasChild) {
    const prompt = buildOverviewPrompt(
      taggedLogs,
      taggedInteractions,
      taggedReflections,
      journalEntriesForPrompt,
      childProfile.display_name ?? "anak",
      childConfidenceTier,
      parentConfidenceTier,
      childProfilesForPrompt,
    );

    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_OVERVIEW") ?? DEFAULT_MODEL,
      // "/no_think" (llm.ts) — cut ~20s to ~7s in testing
      // (PERFORMANCE_COMPARISON.md §8), quality looked comparable on the
      // dummy dataset (still needs the real A/B harness work in ADR-0010's
      // Action Items, this was a smoke test not a rigorous eval).
      jsonSchema: OVERVIEW_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 6000,
    }, 20000); // more generous than followup-eval's 5s — this isn't a real-time UX path
    const parsed = parseJsonResponse<OverviewResult>(result.text);

    overviewFields = {
      headline: parsed.overview.headline,
      summary: parsed.overview.summary,
      patterns: mergePatternsByTopic(parsed.overview.patterns),
      relationship_signal: parsed.overview.relationship_signal,
      communication_style: parsed.overview.communication_style,
      data_confidence: parsed.overview.data_confidence,
      key_insight: parsed.overview.key_insight,
    };
    promptTokens = result.promptTokens;
    outputTokens = result.outputTokens;
  } else {
    const prompt = buildParentOnlyOverviewPrompt(
      journalEntriesForPrompt,
      "anakmu",
      parentConfidenceTier,
      childProfilesForPrompt,
    );

    const result = await callLlmWithFallback(prompt, {
      model: Deno.env.get("OPENROUTER_MODEL_OVERVIEW") ?? DEFAULT_MODEL,
      jsonSchema: PARENT_ONLY_OVERVIEW_JSON_SCHEMA,
      systemPrompt: "/no_think",
      maxOutputTokens: 6000,
    }, 20000);
    const parsed = parseJsonResponse<ParentOnlyOverviewResult>(result.text);

    // Map onto the same storage/client shape as the combined overview.
    // parent_concern has a real basis (assessed from the parent's own
    // reflection entries), so it carries over as-is. child_openness and
    // possible_misalignment have NO basis at all without any child
    // data — sending a fake "low"/false there reads to the parent as a
    // confident (if reassuring) assessment the app never actually made.
    // "tidak tersedia" is a deliberate sentinel: RelationshipSignal's
    // childOpennessText/misalignmentText (Swift) recognize it and show
    // an honest "not available" instead of a fabricated value.
    overviewFields = {
      headline: parsed.overview.headline,
      summary: parsed.overview.summary,
      patterns: mergePatternsByTopic(parsed.overview.patterns),
      relationship_signal: {
        parent_concern: parsed.overview.parent_signal.frustration_level,
        child_openness: "tidak tersedia",
        possible_misalignment: false,
      },
      communication_style: parsed.overview.communication_style,
      data_confidence: { child: "low", parent: parsed.overview.data_confidence },
      key_insight: parsed.overview.key_insight,
    };
    promptTokens = result.promptTokens;
    outputTokens = result.outputTokens;
  }

  // upsert, not insert: `overviews_family_period_idx` (a unique index on
  // family_id+period_start, added separately from this function) rejects
  // a second row for the same family/week outright. Both callers already
  // guard against re-generating an existing period before calling this —
  // a race (e.g. a double-tapped refresh, or the batch job and a missed-
  // cron client fallback landing at the same moment) would otherwise turn
  // into a hard 500 instead of just returning the row. onConflict
  // overwrites with the freshly generated content rather than erroring.
  const { data: inserted, error: insertError } = await supabase
    .from("overviews")
    .upsert({
      family_id: familyId,
      // Client's fetchOverview does an exact-match lookup on these two
      // columns to avoid re-generating (a real LLM call, ~7-20s) on
      // every Ringkasan open — this insert never set them, so that
      // lookup always missed (NULL never equals a real date) and the
      // slow path ran every single time. Root-caused live 2026-09-02.
      period_start: periodStart,
      period_end: periodEnd,
      ...overviewFields,
      raw_response: { promptTokens, outputTokens },
    }, { onConflict: "family_id,period_start" })
    .select()
    .single();

  if (insertError) {
    throw new Error(`insert_failed: ${insertError.message}`);
  }

  return inserted;
}
