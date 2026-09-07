// select-child-log-questions — child-side mirror of
// select-parent-log-questions. Rule-based, NOT an LLM call — same
// "cheap/synchronous, runs before the guided-journal UI's first screen"
// reasoning. Picks a validating affirmation + one open-ended anchor
// question, built from what the child already picked on the
// valence/label/association screens, same mechanism as the parent flow,
// copy reworded to address the child directly (not "orang tua").

import { createUserClient } from "../_shared/supabase-admin.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import type { LogContextField } from "../_shared/prompts.ts";

const ANCHOR_FIELD: LogContextField = "FEELING";

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
  Heat: "Kedengerannya tadi bikin emosi banget ya.",
  Anxious: "Wajar banget kalau lagi ngerasa khawatir soal ini.",
  Heavy: "Kedengerannya berat banget ya hari ini.",
  Flat: "Oke, kadang emang ada momen yang bikin kurang enak gitu.",
  Settled: "Seneng denger kamu ngerasa tenang hari ini.",
  Lifted: "Seneng banget denger harimu berjalan baik!",
};

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

function joinNatural(items: string[]): string {
  const cleaned = items.map((s) => s.trim()).filter(Boolean);
  if (cleaned.length === 0) return "";
  if (cleaned.length === 1) return cleaned[0];
  if (cleaned.length === 2) return `${cleaned[0]} dan ${cleaned[1]}`;
  return `${cleaned.slice(0, -1).join(", ")}, dan ${cleaned[cleaned.length - 1]}`;
}

// Same idea as select-parent-log-questions' CHILD_RELATED_KEYWORDS, mirrored
// for the family/parent side of the relationship — only mention family when
// the picked topic actually looks relationship-shaped, not for a personal
// pick like "Nilai Ujian" or "Tidur Cukup".
const FAMILY_RELATED_KEYWORDS = ["orang tua", "keluarga", "mama", "papa", "ayah", "ibu", "hubungan"];

function isFamilyRelated(associations: string[]): boolean {
  return associations.some((a) => {
    const lower = a.toLowerCase();
    return FAMILY_RELATED_KEYWORDS.some((kw) => lower.includes(kw));
  });
}

const FAMILY_REFERENCE = "orang tuamu";

function buildOpenEndedQuestion(displayLabels: string[], associations: string[]): string {
  const labelsText = joinNatural(displayLabels);
  const associationsText = joinNatural(associations);
  const familyClause = isFamilyRelated(associations) ? ` sama ${FAMILY_REFERENCE}` : "";

  if (labelsText && associationsText) {
    return `Kamu bilang lagi ngerasa ${labelsText} soal ${associationsText}. Cerita dong, kejadiannya gimana${familyClause}?`;
  }
  if (labelsText) {
    return `Kamu bilang lagi ngerasa ${labelsText} hari ini. Cerita dong, kejadiannya gimana${familyClause}?`;
  }
  if (associationsText) {
    return `Kamu bilang ada yang lagi kepikiran soal ${associationsText}. Cerita dong, kejadiannya gimana${familyClause}?`;
  }
  return `Gimana harimu hari ini? Cerita aja apa yang lagi ada di pikiranmu.`;
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
