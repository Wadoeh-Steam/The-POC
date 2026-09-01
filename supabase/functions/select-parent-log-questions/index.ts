// select-parent-log-questions — be1, parent-first scope.
// Rule-based, NOT an LLM call — deliberately cheap/synchronous so this can
// run before the guided-journal UI shows its first screen.
//
// 2026-08-30: rewritten from "3 main questions (1 fixed + 2 from a
// picker-filtered bank)" to a single genuinely open-ended anchor question,
// PLUS an `affirmation` that validates what the parent already selected on
// the valence/label picker screens before this one — per explicit product
// feedback ("harusnya yang ditanya adalah hasil input valence dll dari
// user (si parent) untuk nge validate perasaan parent"). The old fixed Q1
// ("Ada momen apa sama [Nama Anak]...") stays gone — it was flagged as too
// narrow/specific. The randomized question bank (old Q2/Q3) is also gone:
// the 2nd/3rd questions in a guided-journal entry are now LLM-generated
// follow-ups chained off the parent's own answer (see
// evaluate-parent-log-followup), not picked from a static pool.
//
// The affirmation AND the open-ended question itself now use what the
// parent picked (labels/valence for the affirmation's cluster; the
// original display_labels/associations strings for the question's
// wording) — a 2nd revision same day, per further feedback: the opener
// should be ABOUT the picked topic, not just preceded by an affirmation
// that references it while the question stays generic. Stays
// deterministic/templated (not an LLM call) — same "cheap/synchronous, no
// latency before the first screen" reasoning as the rest of this function;
// labels/valence/associations are all closed or bounded inputs a template
// covers well without needing generative text.

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import type { LogContextField } from "../_shared/prompts.ts";

// FEELING is the anchor's field — there's only ever one main question now,
// so no more per-field bank slot-filling to worry about (see
// 20260830000001_guided_journal_chain_flow.sql's sequence-based constraint).
const ANCHOR_FIELD: LogContextField = "FEELING";

// Same six-cluster taxonomy the old randomized question bank used to
// filter its pool — kept here purely to pick a validating sentence, not to
// filter/select questions anymore.
type Cluster = "Heat" | "Anxious" | "Heavy" | "Flat" | "Settled" | "Lifted";

const EMOTION_LABEL_CLUSTERS: Record<string, Cluster> = {
  angry: "Heat",
  frustrated: "Heat",
  irritated: "Heat",
  annoyed: "Heat",
  disgusted: "Heat",
  anxious: "Anxious",
  worried: "Anxious",
  scared: "Anxious",
  stressed: "Anxious",
  overwhelmed: "Anxious",
  sad: "Heavy",
  hopeless: "Heavy",
  lonely: "Heavy",
  drained: "Heavy",
  discouraged: "Heavy",
  guilty: "Heavy",
  ashamed: "Heavy",
  embarrassed: "Heavy",
  disappointed: "Flat",
  jealous: "Flat",
  indifferent: "Flat",
  calm: "Settled",
  content: "Settled",
  peaceful: "Settled",
  relieved: "Settled",
  satisfied: "Settled",
  grateful: "Settled",
  happy: "Lifted",
  joyful: "Lifted",
  proud: "Lifted",
  hopeful: "Lifted",
  confident: "Lifted",
  brave: "Lifted",
  excited: "Lifted",
  passionate: "Lifted",
  amazed: "Lifted",
  amused: "Lifted",
  surprised: "Lifted",
};

const CLUSTER_AFFIRMATION: Record<Cluster, string> = {
  Heat: "Kedengerannya tadi bener-bener bikin emosi ya.",
  Anxious: "Wajar banget kalau lagi ngerasa khawatir soal ini.",
  Heavy: "Kedengerannya berat banget ya hari ini.",
  Flat: "Oke, kadang emang ada momen yang bikin kurang enak gitu.",
  Settled: "Seneng denger kamu ngerasa tenang hari ini.",
  Lifted: "Seneng banget denger harimu berjalan baik!",
};

// Picks the cluster with the most matching labels (first-seen order breaks
// ties). null when none of the parent's quick-pick labels map to a known
// cluster — caller falls back to a valence-based guess in that case.
function deriveClusterFromLabels(labels: string[]): Cluster | null {
  const counts = new Map<Cluster, number>();
  const seenOrder: Cluster[] = [];
  for (const label of labels) {
    const cluster = EMOTION_LABEL_CLUSTERS[label.trim().toLowerCase()];
    if (!cluster) continue;
    if (!counts.has(cluster)) {
      counts.set(cluster, 0);
      seenOrder.push(cluster);
    }
    counts.set(cluster, counts.get(cluster)! + 1);
  }
  if (seenOrder.length === 0) return null;
  let best = seenOrder[0];
  for (const cluster of seenOrder) {
    if (counts.get(cluster)! > counts.get(best)!) best = cluster;
  }
  return best;
}

// Coarse fallback when labels don't map to a known cluster (e.g. empty
// picker selection) — valence alone still lets the affirmation validate
// SOMETHING rather than fall back to a generic non-committal line.
function deriveClusterFromValence(valence: number): Cluster {
  if (valence < -0.33) return "Heavy";
  if (valence > 0.33) return "Lifted";
  return "Flat";
}

function buildAffirmation(labels: string[], valence: number | undefined): string {
  const cluster = deriveClusterFromLabels(labels) ?? (typeof valence === "number" ? deriveClusterFromValence(valence) : null);
  if (!cluster) return "Makasih udah luangin waktu buat cerita hari ini.";
  return CLUSTER_AFFIRMATION[cluster];
}

// Joins picker picks into a natural Indonesian list: "a", "a dan b", or
// "a, b, dan c" — used to make the anchor question actually ABOUT what the
// parent selected, not a topic-blind opener. Per product feedback
// (2026-08-30): "sedih, angry, masalah keuangan -> [validate], open ended
// question about that" — the open-ended question itself should name the
// picked emotions/topics, not just the affirmation before it.
function joinNatural(items: string[]): string {
  const cleaned = items.map((s) => s.trim()).filter(Boolean);
  if (cleaned.length === 0) return "";
  if (cleaned.length === 1) return cleaned[0];
  if (cleaned.length === 2) return `${cleaned[0]} dan ${cleaned[1]}`;
  return `${cleaned.slice(0, -1).join(", ")}, dan ${cleaned[cleaned.length - 1]}`;
}

// `ImpactBulletsView`'s association pills are free-text Indonesian phrases
// per valence bucket (e.g. "Tidur Cukup", "Dukungan Keluarga", "Tekanan
// Keluarga"), not a closed enum — most of them are about the PARENT's own
// life (sleep, work, money, weather...), not the child. Forcing "sama
// [Nama Anak]" onto every question regardless of topic reads as forced/
// nonsensical for a personal-wellbeing pick like "Tidur Cukup" (flagged
// live 2026-08-30: "Kamu bilang lagi ngerasa Senang dan Puas soal Tidur
// Cukup... gimana sama Maya?" doesn't make sense). Only mention the child
// when the picked topic actually looks relationship/family-shaped.
const CHILD_RELATED_KEYWORDS = ["anak", "keluarga", "hubungan"];

function isChildRelated(associations: string[]): boolean {
  return associations.some((a) => {
    const lower = a.toLowerCase();
    return CHILD_RELATED_KEYWORDS.some((kw) => lower.includes(kw));
  });
}

// "anakmu" ("your child"), not the actual name — per explicit product
// instruction (2026-08-30). Distinct from the rest of this codebase, which
// deliberately DOES use the real first name elsewhere (PromptBuilder.swift,
// prompts.ts's personalityRuleId) — that choice stands, this is scoped to
// just this deterministic opener's child-mention clause.
const CHILD_REFERENCE = "anakmu";

// `displayLabels` are the ORIGINAL Indonesian words the parent tapped on
// the emotion picker (e.g. "sedih", "marah") — distinct from `labels`,
// which are the EN EmotionLabelItem.rawValue cluster keys
// (indonesianToEmotionLabel's translation, used only for buildAffirmation's
// cluster matching). `associations` are already Indonesian display strings
// from the picker, no translation needed.
function buildOpenEndedQuestion(displayLabels: string[], associations: string[]): string {
  const labelsText = joinNatural(displayLabels);
  const associationsText = joinNatural(associations);
  const childClause = isChildRelated(associations) ? ` sama ${CHILD_REFERENCE}` : "";

  if (labelsText && associationsText) {
    return `Kamu bilang lagi ngerasa ${labelsText} soal ${associationsText}. Cerita dong, kejadiannya gimana${childClause}?`;
  }
  if (labelsText) {
    return `Kamu bilang lagi ngerasa ${labelsText} hari ini. Cerita dong, kejadiannya gimana${childClause}?`;
  }
  if (associationsText) {
    return `Kamu bilang ada yang lagi kepikiran soal ${associationsText}. Cerita dong, kejadiannya gimana${childClause}?`;
  }
  // No picker signal to anchor on at all (e.g. picker skipped) — the child
  // mention stays here since there's no topic to judge relevance against,
  // and this is otherwise the fully generic opener.
  return `Gimana harimu bareng ${CHILD_REFERENCE} hari ini? Cerita aja apa yang lagi ada di pikiranmu.`;
}

interface RequestBody {
  labels?: string[];
  display_labels?: string[];
  associations?: string[];
  valence?: number;
  valence_classification?: string;
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
  return jsonResponse({
    affirmation: buildAffirmation(body.labels ?? [], body.valence),
    question: {
      field: ANCHOR_FIELD,
      question_text: buildOpenEndedQuestion(body.display_labels ?? [], body.associations ?? []),
    },
  });
});
