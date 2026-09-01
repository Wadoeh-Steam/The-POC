// Indonesian prompts — the reference structure (JSON shapes, cautious-
// language rules) comes from the Phase 0 POC's PromptBuilder.swift, but
// this is a genuine rewrite, not a mechanical translation. See ADR-0007.
//
// The Swift copy (for `on_device` mode, ARCHITECTURE.md §2a) must stay in
// sync with these — same rules, same JSON shapes, different runtime. If
// you change a prompt here, change PromptBuilder.swift too.

export interface EmotionLogForPrompt {
  timestamp: string;
  valence: number;
  valence_classification: string;
  labels: string[];
  associations: string[];
  journal: string | null;
  context_answers?: Partial<Record<LogContextField, string>>;
}

export type LogContextField =
  | "FEELING"
  | "TRIGGER"
  | "PERCEIVED_CAUSE"
  | "PRIOR_EFFORT"
  | "FUTURE_PLAN"
  | "EXPECTED_OUTCOME";

export interface ParentInteractionForPrompt {
  timestamp: string;
  topic: string;
  interaction: string;
  parent_emotion: string | null;
}

export interface ParentReflectionForPrompt {
  timestamp: string;
  emotion: string;
  note: string | null;
}

const FIELD_LABEL_ID: Record<LogContextField, string> = {
  FEELING: "perasaan",
  TRIGGER: "pemicu",
  PERCEIVED_CAUSE: "dugaan penyebab",
  PRIOR_EFFORT: "usaha yang sudah dilakukan",
  FUTURE_PLAN: "rencana ke depan",
  EXPECTED_OUTCOME: "harapan hasil",
};

// Deliberately uses valence_classification (a category), not the raw
// valence float — the prompts below all instruct the model not to cite
// raw numbers, so the compact representation shouldn't hand it one either.
function compactLog(log: EmotionLogForPrompt): string {
  const parts = [
    log.timestamp.slice(0, 10),
    `suasana=${log.valence_classification}`,
  ];
  if (log.labels.length) parts.push(`label=[${log.labels.join(",")}]`);
  if (log.associations.length) {
    parts.push(`konteks=[${log.associations.join(",")}]`);
  }
  if (log.journal) parts.push(`catatan="${log.journal}"`);
  if (log.context_answers) {
    for (const [field, answer] of Object.entries(log.context_answers)) {
      if (answer) {
        parts.push(`${FIELD_LABEL_ID[field as LogContextField]}="${answer}"`);
      }
    }
  }
  return "- " + parts.join(" | ");
}

function compactLogs(logs: EmotionLogForPrompt[]): string {
  return logs.map(compactLog).join("\n");
}

function compactParentContext(
  interactions: ParentInteractionForPrompt[],
  reflections: ParentReflectionForPrompt[],
): string {
  const lines: string[] = [];
  for (const i of interactions) {
    lines.push(
      `- ${i.timestamp.slice(0, 10)} [${i.topic}] "${i.interaction}"` +
        (i.parent_emotion ? ` (perasaan orang tua: ${i.parent_emotion})` : ""),
    );
  }
  if (reflections.length) {
    lines.push("Catatan refleksi orang tua:");
    for (const r of reflections) {
      lines.push(
        `- ${r.timestamp.slice(0, 10)} merasa ${r.emotion}` +
          (r.note ? `: "${r.note}"` : ""),
      );
    }
  }
  return lines.join("\n");
}

const CAUTIOUS_LANGUAGE_RULE_ID = `Gunakan bahasa hati-hati saja: "mungkin", "tampaknya", "kemungkinan polanya adalah", "bisa jadi menunjukkan". \
Jangan pernah gunakan: "mengalami gangguan", "depresi", "ini membuktikan bahwa". \
Jangan mendiagnosis. Jangan menyalahkan salah satu pihak (anak atau orang tua).`;

// First name only — reads personal ("Maya"), not formal/clinical ("Maya
// Anderson"), in a warm-address sentence. Kept in sync with
// PromptBuilder.swift's firstName().
function firstName(fullName: string): string {
  return fullName.split(" ")[0] ?? fullName;
}

// Kept in sync with PromptBuilder.swift's personalityRule. Assertive in
// DELIVERY/confidence only — cautiousLanguageRule (hedging on claims about
// the child) is a safety guardrail this persona doesn't override.
function personalityRuleId(childName: string): string {
  return `Kamu pendamping keluarga bijaksana usia 50-an — tegas dan percaya diri, bukan ragu-ragu atau klinis. Validasi juga perasaan orang tua. Sebut ${childName} di TENGAH kalimat, JANGAN sebagai sapaan pembuka ("${childName}, ...") — kamu bicara KEPADA orang tua TENTANG ${childName}, bukan kepada ${childName} langsung (kecuali di dalam kutipan skrip di bawah, di situ boleh menyapa anak).`;
}

// Kept in sync with PromptBuilder.swift's quoteRule — the client renders
// quoted spans as a separate highlighted block (QuoteAwareText), so this
// explicitly forbids wrapping the whole answer in quotes (observed live,
// 2026-08-20: the model did exactly that on the first wording).
const QUOTE_RULE_ID =
  `Sertakan TEPAT satu kalimat lengkap (bukan potongan 2-3 kata) dalam tanda kutip ganda — kalimat spesifik yang bisa diucapkan orang tua ke anak, casual dan hangat kayak orang tua asli ngomong ("aku"/"kamu", boleh "nak"/"sayang"/"mama tau"), BUKAN bahasa formal ("saya"/"Anda"). Sisanya tetap tanpa kutip — jangan bungkus seluruh jawabanmu dalam tanda kutip.`;

// ============================================================================
// 1. Extraction + crisis-signal check (check-log-context, ARCHITECTURE.md §3a, §2b)
// ============================================================================

const CONTEXT_FIELDS: LogContextField[] = [
  "FEELING",
  "TRIGGER",
  "PERCEIVED_CAUSE",
  "PRIOR_EFFORT",
  "FUTURE_PLAN",
  "EXPECTED_OUTCOME",
];

export interface ExtractionResult {
  extracted: Partial<Record<LogContextField, string>>;
  crisis_signal: boolean;
}

export function buildExtractionPrompt(draft: {
  valence: number;
  labels: string[];
  associations: string[];
  journal: string | null;
}): string {
  return `Kamu membantu memproses catatan emosi harian yang ditulis oleh seorang anak/remaja.

Anak menulis catatan berikut (jika ada teks bebas):
"${draft.journal ?? "(tidak ada teks, hanya pilihan cepat)"}"

Info tambahan dari pilihan cepat: label=[${draft.labels.join(",")}], konteks=[${draft.associations.join(",")}]

Tugas 1 — Ekstraksi konteks:
Untuk masing-masing dari 6 aspek berikut, tentukan apakah nilainya SUDAH ada di teks anak (kutip/ringkas dari teksnya sendiri) atau BELUM ADA sama sekali:
- FEELING: perasaan anak saat ini
- TRIGGER: apa yang memicu perasaan itu
- PERCEIVED_CAUSE: menurut anak, apa penyebab/masalahnya
- PRIOR_EFFORT: usaha apa yang sudah dicoba anak untuk mengatasinya
- FUTURE_PLAN: rencana anak ke depan untuk mengatasi/mencegah ini terulang
- EXPECTED_OUTCOME: harapan anak terhadap hasil dari rencana itu

Jangan mengarang jawaban — kalau tidak ada di teks anak, tandai null. Jangan menyimpulkan lebih dari yang tertulis.

Tugas 2 — Sinyal krisis:
Tandai true HANYA jika teks anak menunjukkan indikasi serius menyakiti diri sendiri, keinginan bunuh diri, atau bahaya langsung terhadap keselamatan anak. Jangan tandai true untuk emosi negatif biasa (sedih, stres, marah) — hanya untuk sinyal krisis yang jelas.

Output HARUS JSON valid, tanpa markdown, persis bentuk ini:
{
  "extracted": {
    "FEELING": "<isi atau null>",
    "TRIGGER": "<isi atau null>",
    "PERCEIVED_CAUSE": "<isi atau null>",
    "PRIOR_EFFORT": "<isi atau null>",
    "FUTURE_PLAN": "<isi atau null>",
    "EXPECTED_OUTCOME": "<isi atau null>"
  },
  "crisis_signal": true or false
}`;
}

export function missingFieldsFrom(
  extracted: Partial<Record<LogContextField, string | null>>,
): LogContextField[] {
  return CONTEXT_FIELDS.filter((f) => !extracted[f]);
}

// For OpenRouter's response_format: json_schema (ADR-0010) — enforced
// server-side by providers that support it, falls back to the prompt's
// own written-out shape (+ stripFences) for providers that don't.
export const EXTRACTION_JSON_SCHEMA = {
  name: "log_context_extraction",
  schema: {
    type: "object",
    properties: {
      extracted: {
        type: "object",
        properties: Object.fromEntries(
          CONTEXT_FIELDS.map((f) => [f, { type: ["string", "null"] }]),
        ),
        required: CONTEXT_FIELDS,
        additionalProperties: false,
      },
      crisis_signal: { type: "boolean" },
    },
    required: ["extracted", "crisis_signal"],
    additionalProperties: false,
  },
};

// ============================================================================
// 2. How-to-react tip (generate-how-to-react, ARCHITECTURE.md §4)
// Plain LLM, no RAG/trusted-source grounding — deferred, see PLAN.md Phase 5.
// ============================================================================

export function buildHowToReactPrompt(log: EmotionLogForPrompt, childName: string): string {
  const name = firstName(childName);
  return `Kamu adalah asisten yang membantu orang tua memahami dan merespons catatan emosi anaknya dengan empati.

Anak (nama: ${name}) baru saja mencatat:
${compactLog(log)}

Tulis SATU tip singkat (maksimal 2 kalimat, bahasa Indonesia, plain text tanpa markdown) untuk orang tua tentang bagaimana sebaiknya merespons momen ini. ${CAUTIOUS_LANGUAGE_RULE_ID} ${personalityRuleId(name)} ${QUOTE_RULE_ID}

Fokus pada nada dan pendekatan (misal: dengarkan dulu tanpa menghakimi, tanyakan tanpa memaksa), bukan solusi teknis. Jangan berikan saran medis atau psikologis spesifik.`;
}

// ============================================================================
// 3. Relationship Overview (generate-overview) — ports PromptBuilder.overviewPrompt
// ============================================================================

// Wrapper types, not extensions of EmotionLogForPrompt/ParentInteractionFor
// Prompt/ParentReflectionForPrompt — those base types are shared with
// buildHowToReactPrompt/buildReflectionPrompt, which don't need [spesifik]/
// [general] tagging. Keeping the tag on a wrapper avoids forcing an unused
// field onto callers that don't have this concept.
export interface TaggedEmotionLogForPrompt {
  log: EmotionLogForPrompt;
  isSpecific: boolean;
}

export interface TaggedParentInteractionForPrompt {
  interaction: ParentInteractionForPrompt;
  isSpecific: boolean;
}

export interface TaggedParentReflectionForPrompt {
  reflection: ParentReflectionForPrompt;
  isSpecific: boolean;
}

export interface OverviewResult {
  overview: {
    headline: string;
    summary: string;
    patterns: { topic: string; observation: string; suggested_approach: string }[];
    relationship_signal: {
      parent_concern: "low" | "moderate" | "high";
      child_openness: "low" | "moderate" | "high";
      possible_misalignment: boolean;
    };
    communication_style: {
      detected_pattern: "bald_on_record" | "autonomy_supportive" | "unclear";
      example_before: string | null;
      example_after: string | null;
    };
    data_confidence: {
      child: ConfidenceTier;
      parent: ConfidenceTier;
    };
    key_insight: string;
  };
}

// Self-Determination Theory, translated into a concrete rule the model can
// follow: acknowledge the child's feeling BEFORE the parent's own
// perspective, and prefer language that leaves the child a choice over
// direct commands. "Bald-on-record speech" (Brown & Levinson) is the
// pattern being screened for in the parent's own logged interactions —
// direct imperatives that attack the child's autonomy ("kamu harus...",
// "pokoknya wajib..."). Decision to change the overview from purely
// descriptive to this more directive coaching format: 2026-08-25 — see
// context.md, supersedes the earlier "stays descriptive" call.
const AUTONOMY_SUPPORTIVE_RULE_ID =
  `Untuk "suggested_approach" dan "communication_style": dasarkan pada Self-Determination Theory — anak perlu merasa otonom (bukan dikontrol), bukan berarti dibiarkan tanpa arahan. \
Prinsip utama: akui dulu perasaan anak secara eksplisit SEBELUM masuk ke perspektif/harapan orang tua — jangan langsung kasih nasihat satu arah. \
Kalau di catatan interaksi orang tua ada kalimat yang sifatnya perintah langsung/bald-on-record (menyerang otonomi anak — misal "kamu harus...", "pokoknya kamu wajib...", "jangan bantah, lakukan aja"), set detected_pattern = "bald_on_record", kutip kalimat aslinya (atau parafrase dekat) di example_before, dan tulis versi non-controlling-nya di example_after — ganti perintah langsung jadi kalimat yang kasih ruang pilihan (contoh: "kamu harus beresin kamar sekarang" -> "mungkin lebih enak kalau kamarnya dirapiin sebelum makan malam, gimana?"). Kalau nggak ada indikasi jelas di data yang ada, detected_pattern = "unclear" — JANGAN memaksakan contoh yang tidak benar-benar ada di catatan — dan example_before/example_after diisi null.`;

// Presenting patterns as data rather than verdicts is deliberate: parents
// are naturally invested and struggle to evaluate their own choices
// objectively, and in high power-distance cultures (Indonesia's PDI = 78)
// tend to default to demanding obedience when they feel judged. Framing as
// "pola yang tercatat" rather than "kamu selalu..." is meant to route
// around that defensive reaction, not soften the finding itself.
const DATA_NOT_JUDGMENT_RULE_ID =
  `Sajikan setiap "observation" sebagai POLA DARI DATA yang tercatat, bukan penilaian ke orang tua. Bukan "kamu terlalu memaksa soal beres-beres", tapi "pola yang tercatat: percakapan soal beres-beres di hari Kamis cenderung diikuti penurunan mood anak". Kalau ada pola waktu/hari/topik yang jelas kelihatan dari data, sebutkan spesifik (hari, topik) — itu yang bikin suggested_approach kerasa actionable, bukan generik. Jangan mengarang pola yang tidak benar-benar didukung datanya.`;

// isSpecific mirrors the same has_cognitive_mechanism test as §5/§6 (see
// COGNITIVE_MECHANISM_RULE_ID) — applied here to the child's own logs and
// the parent's interactions/reflections, not just the be1 guided journal.
// Tagging + entryCount/specificEntryCount/confidenceTier are all computed
// by the caller and passed in as-is, same rule as buildParentOnlyOverviewPrompt.
function compactLogsTagged(entries: TaggedEmotionLogForPrompt[]): string {
  return entries
    .map(({ log, isSpecific }) => `- [${isSpecific ? "spesifik" : "general"}] ${compactLog(log).slice(2)}`)
    .join("\n");
}

function compactParentContextTagged(
  interactions: TaggedParentInteractionForPrompt[],
  reflections: TaggedParentReflectionForPrompt[],
): string {
  const lines: string[] = [];
  for (const { interaction: i, isSpecific } of interactions) {
    const tag = isSpecific ? "spesifik" : "general";
    lines.push(
      `- [${tag}] ${i.timestamp.slice(0, 10)} [${i.topic}] "${i.interaction}"` +
        (i.parent_emotion ? ` (perasaan orang tua: ${i.parent_emotion})` : ""),
    );
  }
  if (reflections.length) {
    lines.push("Catatan refleksi orang tua:");
    for (const { reflection: r, isSpecific } of reflections) {
      const tag = isSpecific ? "spesifik" : "general";
      lines.push(
        `- [${tag}] ${r.timestamp.slice(0, 10)} merasa ${r.emotion}` +
          (r.note ? `: "${r.note}"` : ""),
      );
    }
  }
  return lines.join("\n");
}

export function buildOverviewPrompt(
  logs: TaggedEmotionLogForPrompt[],
  interactions: TaggedParentInteractionForPrompt[],
  reflections: TaggedParentReflectionForPrompt[],
  guidedJournalEntries: ParentLogEntryForPrompt[],
  childName: string,
  childConfidenceTier: ConfidenceTier,
  parentConfidenceTier: ConfidenceTier,
): string {
  const name = firstName(childName);
  const childSpecificCount = logs.filter((l) => l.isSpecific).length;
  const parentEntryCount = interactions.length + reflections.length + guidedJournalEntries.length;
  const parentSpecificCount =
    interactions.filter((i) => i.isSpecific).length +
    reflections.filter((r) => r.isSpecific).length +
    guidedJournalEntries.filter((e) => e.isSpecific).length;
  return `Kamu adalah asisten keluarga yang empatik. Tugasmu menggabungkan catatan emosi anak dengan konteks dari orang tua menjadi ringkasan hubungan yang hati-hati dan tidak menghakimi, DAN memberi penyesuaian komunikasi yang konkret, spesifik, dan low-effort untuk minggu ini. Tujuannya membantu orang tua memahami perspektif anaknya dengan lebih berempati, dan pindah dari nasihat satu arah ke memvalidasi perasaan anak dulu.

Data minggu ini:
- Anak: ${logs.length} catatan, ${childSpecificCount} di antaranya spesifik. Confidence: ${childConfidenceTier}.
- Orang tua: ${parentEntryCount} catatan, ${parentSpecificCount} di antaranya spesifik. Confidence: ${parentConfidenceTier}.

Catatan emosi anak (minggu terakhir, ditandai [spesifik] atau [general] per catatan):
${compactLogsTagged(logs)}
Konteks dari orang tua (interaksi terakhir dan refleksi, ditandai [spesifik] atau [general] per catatan):
${compactParentContextTagged(interactions, reflections)}
Jurnal terpandu orang tua (guided journal minggu ini, ditandai [spesifik] atau [general] per catatan — ini biasanya sumber paling kaya karena orang tua diajak cerita lebih dalam soal satu momen):
${compactParentLogEntries(guidedJournalEntries)}

Buat ringkasan terstruktur sebagai JSON saja, persis bentuk ini:

{
  "overview": {
    "headline": "<1 kalimat pendek, maks 10 kata, hati-hati>",
    "summary": "<1-2 kalimat singkat tentang pola keseluruhan, hati-hati>",
    "patterns": [
      {
        "topic": "Pendidikan|Pertemanan|Keluarga|Lainnya",
        "observation": "<1 kalimat pendek, hati-hati, sespesifik data-nya — sebut hari/konteks kalau polanya jelas>",
        "suggested_approach": "<1 kalimat: penyesuaian komunikasi konkret buat pola ini minggu depan, mulai dengan mengakui perasaan anak dulu>"
      }
    ],
    "relationship_signal": {
      "parent_concern": "low|moderate|high",
      "child_openness": "low|moderate|high",
      "possible_misalignment": true
    },
    "communication_style": {
      "detected_pattern": "bald_on_record|autonomy_supportive|unclear",
      "example_before": "<kutipan/parafrase dekat dari catatan orang tua, atau null>",
      "example_after": "<versi non-controlling-nya, atau null>"
    },
    "data_confidence": {
      "child": "<gunakan nilai yang diberikan di atas apa adanya — JANGAN dihitung ulang sendiri>",
      "parent": "<gunakan nilai yang diberikan di atas apa adanya — JANGAN dihitung ulang sendiri>"
    },
    "key_insight": "<1 kalimat pendek yang menghubungkan perspektif orang tua dan anak sebagai kemungkinan, bukan fakta>"
  }
}

Aturan:
- Maksimal 3 "patterns" — kalau data cuma cukup mendukung 1-2 pola yang solid, kirim 1-2 aja. Jangan dipaksakan sampai 3.
- Kalau ada jurnal terpandu [spesifik], jadikan itu dasar utama pattern/suggested_approach — datanya paling detail dibanding catatan lain.
- Fokus pada pola lintas beberapa catatan, bukan satu kejadian tunggal.
- Perlakukan catatan emosi sebagai sinyal, bukan kebenaran objektif.
- Catatan yang ditandai [general] adalah sinyal LEMAH, bukan sinyal kosong. Jangan jadikan catatan [general] sebagai dasar utama sebuah "pola" — tapi tetap boleh disebut sebagai konteks. Dasarkan klaim pola terutama pada catatan [spesifik].
- Kalau data_confidence.child adalah "low" — biasanya karena catatan anak minggu ini cuma 1-2 kali, atau sebagian besar [general] — JANGAN klaim adanya "pola" dari sisi anak. Cukup deskripsikan apa yang ada apa adanya (misal "baru ada satu catatan minggu ini, belum cukup untuk melihat pola"), dan child_openness/possible_misalignment harus mencerminkan keterbatasan ini, bukan disimpulkan seolah datanya lengkap.
- ${CAUTIOUS_LANGUAGE_RULE_ID}
- ${AUTONOMY_SUPPORTIVE_RULE_ID}
- ${DATA_NOT_JUDGMENT_RULE_ID}
- ${personalityRuleId(name)} (berlaku untuk summary dan key_insight)
- ${QUOTE_RULE_ID}
- Pertimbangkan perspektif anak maupun orang tua.
- Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.`;
}

export const OVERVIEW_JSON_SCHEMA = {
  name: "relationship_overview",
  schema: {
    type: "object",
    properties: {
      overview: {
        type: "object",
        properties: {
          headline: { type: "string" },
          summary: { type: "string" },
          patterns: {
            type: "array",
            items: {
              type: "object",
              properties: {
                topic: { type: "string" },
                observation: { type: "string" },
                suggested_approach: { type: "string" },
              },
              required: ["topic", "observation", "suggested_approach"],
              additionalProperties: false,
            },
          },
          relationship_signal: {
            type: "object",
            properties: {
              parent_concern: { type: "string", enum: ["low", "moderate", "high"] },
              child_openness: { type: "string", enum: ["low", "moderate", "high"] },
              possible_misalignment: { type: "boolean" },
            },
            required: ["parent_concern", "child_openness", "possible_misalignment"],
            additionalProperties: false,
          },
          communication_style: {
            type: "object",
            properties: {
              detected_pattern: { type: "string", enum: ["bald_on_record", "autonomy_supportive", "unclear"] },
              example_before: { type: ["string", "null"] },
              example_after: { type: ["string", "null"] },
            },
            required: ["detected_pattern", "example_before", "example_after"],
            additionalProperties: false,
          },
          data_confidence: {
            type: "object",
            properties: {
              child: { type: "string", enum: ["low", "building", "high"] },
              parent: { type: "string", enum: ["low", "building", "high"] },
            },
            required: ["child", "parent"],
            additionalProperties: false,
          },
          key_insight: { type: "string" },
        },
        required: [
          "headline",
          "summary",
          "patterns",
          "relationship_signal",
          "communication_style",
          "data_confidence",
          "key_insight",
        ],
        additionalProperties: false,
      },
    },
    required: ["overview"],
    additionalProperties: false,
  },
};

// ============================================================================
// 4. Reflection Recommendations (generate-reflection, MVP2)
// ============================================================================

export interface ReflectionResult {
  recommendations: {
    title: string;
    description: string;
    based_on: string;
  }[];
}

export function buildReflectionPrompt(
  logs: EmotionLogForPrompt[],
  interactions: ParentInteractionForPrompt[],
  reflections: ParentReflectionForPrompt[],
  childName: string,
): string {
  const name = firstName(childName);
  return `Kamu adalah asisten keluarga yang empatik. Berdasarkan seluruh riwayat catatan emosi anak dan konteks orang tua, berikan rekomendasi refleksi untuk membantu orang tua terhubung lebih baik dengan anaknya.

Seluruh riwayat catatan emosi anak:
${compactLogs(logs)}

Konteks dari orang tua:
${compactParentContext(interactions, reflections)}

Buat 2-3 rekomendasi refleksi singkat sebagai JSON saja, persis bentuk ini:

{
  "recommendations": [
    {
      "title": "<judul singkat, netral>",
      "description": "<1 kalimat singkat saran refleksi/tindakan untuk orang tua, hati-hati>",
      "based_on": "<1 frasa singkat pola apa dari data yang mendasari rekomendasi ini>"
    }
  ]
}

Aturan:
- Rekomendasi berupa ajakan refleksi/percakapan, bukan instruksi medis atau psikologis.
- Dasarkan pada pola berulang, bukan kejadian tunggal.
- ${CAUTIOUS_LANGUAGE_RULE_ID}
- ${personalityRuleId(name)} (berlaku untuk description)
- ${QUOTE_RULE_ID}
- Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.`;
}

export const REFLECTION_JSON_SCHEMA = {
  name: "reflection_recommendations",
  schema: {
    type: "object",
    properties: {
      recommendations: {
        type: "array",
        items: {
          type: "object",
          properties: {
            title: { type: "string" },
            description: { type: "string" },
            based_on: { type: "string" },
          },
          required: ["title", "description", "based_on"],
          additionalProperties: false,
        },
      },
    },
    required: ["recommendations"],
    additionalProperties: false,
  },
};

// ============================================================================
// 5. Guided journal follow-up evaluation (evaluate-parent-log-followup, be1)
//
// Deliberately NOT the LogContextField/ExtractionResult mechanism above —
// that stays untouched for check-log-context. This mechanism's trigger is
// presence/absence of "cognitive mechanism" words (causal + insight
// language), per Baikie & Wilhelm 2005 (expressive writing / LIWC
// categories): participants who moved from "I was overwhelmed" to "I was
// overwhelmed because the deadline moved" showed more benefit than those
// who stayed at the bare feeling statement. crisis_signal is kept for
// schema consistency with the extraction shape above, but its handling on
// the parent-log path is backlogged (not wired to crisis_events yet) —
// see context.md.
// ============================================================================

export interface FollowupEvaluationResult {
  affirmation: string;
  followup_question: string;
  crisis_signal: boolean;
}

// Fixed 3-question arc (anchor + 2 follow-ups), always asked — not gated
// on a "shallow vs deep" classification anymore. User feedback
// (2026-09-01): a conditional gate meant the chain sometimes stopped
// after just the anchor, and the last question she did get didn't read as
// a real close ("nggak ngasih closing yang fulfilling"). followupNumber 1
// digs into WHY; 2 is the deliberate close (impact/what's next), not
// another "kenapa" — that's what makes it feel resolved instead of cut off.
function followupStageInstruction(followupNumber: 1 | 2): string {
  if (followupNumber === 1) {
    return `Follow-up ini gali KENAPA — ajak orang tua cerita alasan/penyebab di balik apa yang baru diceritakan. Contoh: "Kira-kira kenapa kamu ngerasa begitu?", "Menurut kamu apa yang bikin itu kejadian?"`;
  }
  return `Follow-up ini PENUTUP obrolan — JANGAN tanya "kenapa" lagi (udah ditanya di follow-up sebelumnya). Ajak refleksi ke DAMPAK atau LANGKAH KE DEPAN biar obrolannya kerasa selesai, bukan gantung. Contoh: "Terus itu ngaruh ke gimana kamu liat dia sekarang?", "Ada yang pengen kamu coba beda abis ini?"`;
}

export function buildFollowupEvaluationPrompt(
  questionText: string,
  answerText: string,
  followupNumber: 1 | 2,
): string {
  const affirmationInstruction = followupNumber === 1
    ? `Tulis SATU kalimat pendek yang mengakui perasaan orang tua dari jawabannya — bukan menilai. Ini reaksi PERTAMA di obrolan ini, boleh pakai nada hangat/seruan kayak "Wah..."/"Aduh..." kalau emang pas.`
    : `Tulis SATU kalimat pendek yang mengakui perasaan orang tua dari jawabannya — bukan menilai. Ini BUKAN reaksi pertama lagi — JANGAN pakai pembuka seruan yang sama kayak "wah"/"aduh" lagi, kedengerannya dibuat-buat kalau diulang ("sok asik"). Pakai kalimat yang lebih tenang dan personal, kayak beneran nyimak.`;

  return `Kamu bantu lanjutin obrolan guided journal (catatan reflektif harian) orang tua.

Pertanyaan sebelumnya: "${questionText}"
Jawaban orang tua: "${answerText}"

Tugas 1 — Afirmasi:
${affirmationInstruction}

Tugas 2 — Follow-up:
${followupStageInstruction(followupNumber)}
Ambil KATA KUNCI dari jawaban orang tua sendiri biar berasa nyambung, bukan pertanyaan generik. Lebih baik pertanyaan TERBUKA daripada pilihan A-atau-B. JANGAN pakai sapaan formal seperti "Bu/Pak", "Ibu/Bapak".

Tugas 3 — Sinyal krisis:
Tandai true HANYA jika jawaban menunjukkan indikasi serius menyakiti diri sendiri, keinginan bunuh diri, atau bahaya langsung terhadap keselamatan. Jangan tandai true untuk emosi negatif biasa (capek, sedih, stres).

Contoh:
- [follow-up ke-1, gali kenapa] Jawaban: "Aku capek banget ngurusin dia hari ini." -> afirmasi: "Kedengerannya hari ini berat banget ya." ; follow-up: "Kira-kira apa yang bikin paling capek, coba cerita?"
- [follow-up ke-2, penutup] Jawaban: "Soalnya dia susah banget diomongin, tiap saran ditolak." -> afirmasi: "Oke, jadi rasanya kayak usaha kamu belum nyampe ke dia ya." ; follow-up: "Kalau boleh tau, kamu pengen hubungan kalian jadi kayak gimana ke depannya?"

Output HARUS JSON valid, tanpa markdown, persis bentuk ini:
{
  "affirmation": "<kalimat afirmasi singkat>",
  "followup_question": "<pertanyaan follow-up singkat>",
  "crisis_signal": true or false
}`;
}

export const FOLLOWUP_EVALUATION_JSON_SCHEMA = {
  name: "followup_evaluation",
  schema: {
    type: "object",
    properties: {
      affirmation: { type: "string" },
      followup_question: { type: "string" },
      crisis_signal: { type: "boolean" },
    },
    required: ["affirmation", "followup_question", "crisis_signal"],
    additionalProperties: false,
  },
};

// ============================================================================
// 5b. Per-entry journal insight (be1, end-of-chain synthesis)
//
// Runs once, after the guided-journal question chain ends (either
// has_cognitive_mechanism came back true, or the 3-question hard cap was
// hit) — client-side only, nothing persisted yet at this point (matches
// this codebase's "client holds answers in memory until submit" rule).
// Distinct from buildOverviewPrompt (§3): that one is weekly, cross-entry,
// and combines child + parent data. This is single-entry, immediate, and
// parent-only — purely a "here's what I heard" reflection back to the
// parent before they review and send, per the flow diagram's "LLM process
// insight of overall answers" -> "Display Journal Insight" step.

export interface JournalInsightResult {
  kesimpulan: string;
  validasi_emosi: string;
}

export function buildJournalInsightPrompt(
  qaPairs: { question: string; answer: string }[],
  childName: string,
): string {
  // "anakmu" ("your child") when no real name is known yet — e.g. solo
  // mode, no child paired (ARCHITECTURE.md §3b). Same generic reference
  // select-parent-log-questions' CHILD_REFERENCE uses for its opener, and
  // for the same reason: composes into personalityRuleId's instructions
  // ("Sebut anakmu di tengah kalimat...") without needing a real name.
  const name = firstName(childName.trim() || "anakmu");
  const transcript = qaPairs.map((qa) => `T: ${qa.question}\nJ: ${qa.answer}`).join("\n\n");
  return `Kamu asisten keluarga yang empatik. Orang tua baru saja mengisi guided journal singkat soal harinya. Berikut percakapannya:

${transcript}

Buat ringkasan singkat sebagai JSON saja, persis bentuk ini:
{
  "kesimpulan": "<1-2 kalimat singkat, hati-hati, merangkum apa yang diceritakan orang tua>",
  "validasi_emosi": "<1-2 kalimat yang mengakui/memvalidasi perasaan orang tua sebagai hal yang wajar, bukan menilai>"
}

Aturan:
- ${CAUTIOUS_LANGUAGE_RULE_ID}
- ${personalityRuleId(name)}
- Sebut ${name} HANYA kalau jawaban orang tua di atas emang nyeritain soal ${name} atau interaksi sama ${name}. Kalau topiknya soal hal lain (pekerjaan, tidur, kondisi diri sendiri, dll), jangan dipaksain nyebut ${name} sama sekali.
- Jangan menyimpulkan lebih dari yang benar-benar tersirat dari jawaban di atas.
- Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.`;
}

export const JOURNAL_INSIGHT_JSON_SCHEMA = {
  name: "journal_insight",
  schema: {
    type: "object",
    properties: {
      kesimpulan: { type: "string" },
      validasi_emosi: { type: "string" },
    },
    required: ["kesimpulan", "validasi_emosi"],
    additionalProperties: false,
  },
};

// ============================================================================
// 6. Parent-only overview (be1, parent-side-only path)
//
// Distinct from buildOverviewPrompt (§3): that one combines child emotion
// logs + parent context and can make cautious claims about the child's
// side. This one runs when there's no child data to draw on yet (child
// hasn't onboarded/logged) — the model has ONLY the parent's own guided-
// journal entries (parent_log_entries/parent_log_answers, be1) and must
// never assert the child's feelings/perspective as fact.
//
// entryCount/specificEntryCount/confidenceTier are computed by the caller
// and passed in as-is — this function does not recompute confidence.
// "specific" per entry uses the same has_cognitive_mechanism test as
// evaluate-parent-log-followup's COGNITIVE_MECHANISM_RULE_ID (a proxy: an
// entry with no 'followup' row for a field means the main answer already
// had cognitive-mechanism words, i.e. was specific).
//
// Not yet wired to a caller — no edge function invokes this yet, same as
// select-parent-log-questions before it was wired up. Whoever adds the
// caller also needs to decide entryCount/specificEntryCount/confidenceTier's
// exact computation (this file only consumes them).
// ============================================================================

export interface ParentLogEntryForPrompt {
  timestamp: string;
  isSpecific: boolean;
  answers: { field: LogContextField; questionText: string; answerText: string }[];
}

export type ConfidenceTier = "low" | "building" | "high";

// Placeholder tier thresholds — not tuned/validated against real usage, same
// "not finalized" caveat as PromptBuilder.valenceClassification's placeholder
// thresholds. Callers (generate-overview, a future generate-parent-only-
// overview) use this so confidence isn't silently invented ad hoc per call
// site; swap the thresholds here once there's real UX data to tune against.
export function deriveConfidenceTier(entryCount: number, specificEntryCount: number): ConfidenceTier {
  if (entryCount === 0) return "low";
  const specificRatio = specificEntryCount / entryCount;
  if (entryCount >= 3 && specificRatio >= 0.5) return "high";
  if (entryCount >= 2 && specificRatio >= 0.25) return "building";
  return "low";
}

export interface ParentOnlyOverviewResult {
  overview: {
    headline: string;
    summary: string;
    patterns: { topic: string; observation: string; suggested_approach: string }[];
    parent_signal: {
      frustration_level: "low" | "moderate" | "high";
      reflection_depth: "surface" | "building" | "specific";
    };
    communication_style: {
      detected_pattern: "bald_on_record" | "autonomy_supportive" | "unclear";
      example_before: string | null;
      example_after: string | null;
    };
    data_confidence: ConfidenceTier;
    key_insight: string;
  };
}

function compactParentLogEntries(entries: ParentLogEntryForPrompt[]): string {
  return entries
    .map((e) => {
      const tag = e.isSpecific ? "[spesifik]" : "[general]";
      const qa = e.answers
        .map((a) => `${FIELD_LABEL_ID[a.field]}: "${a.questionText}" -> "${a.answerText}"`)
        .join(" | ");
      return `- ${e.timestamp.slice(0, 10)} ${tag} ${qa}`;
    })
    .join("\n");
}

export function buildParentOnlyOverviewPrompt(
  entries: ParentLogEntryForPrompt[],
  childName: string,
  confidenceTier: ConfidenceTier,
): string {
  const name = firstName(childName);
  const specificCount = entries.filter((e) => e.isSpecific).length;
  return `Kamu adalah pelatih pribadi yang empatik untuk orang tua. Tugasmu menganalisis catatan refleksi orang tua sendiri (minggu ini) untuk membantu mereka membangun kosakata emosi dan pola komunikasi yang lebih autonomy-supportive — SEBELUM mereka mempraktikkannya ke anak. Kamu TIDAK punya data dari anak sama sekali di tahap ini, jadi jangan pernah membuat klaim atau tebakan pasti tentang perasaan atau sudut pandang anak.

Data minggu ini: ${entries.length} catatan orang tua, ${specificCount} di antaranya spesifik (mengandung kata sebab-akibat/insight). Confidence level minggu ini: ${confidenceTier}.

Catatan refleksi orang tua (minggu ini, ditandai [spesifik] atau [general] per catatan):
${compactParentLogEntries(entries)}

Buat ringkasan terstruktur sebagai JSON saja, persis bentuk ini:
{
  "overview": {
    "headline": "<1 kalimat pendek, maks 10 kata, hati-hati>",
    "summary": "<1-2 kalimat tentang pola yang muncul DI CATATAN ORANG TUA SENDIRI minggu ini — bukan tentang keadaan anak>",
    "patterns": [
      {
        "topic": "Pendidikan|Pertemanan|Keluarga|Lainnya",
        "observation": "<1 kalimat pendek, hati-hati, tentang pola dalam cara orang tua bercerita atau bereaksi — sespesifik data-nya>",
        "suggested_approach": "<1 kalimat: penyesuaian komunikasi konkret buat dicoba minggu depan, mulai dengan mengakui perasaan anak dulu>"
      }
    ],
    "parent_signal": {
      "frustration_level": "low|moderate|high",
      "reflection_depth": "surface|building|specific"
    },
    "communication_style": {
      "detected_pattern": "bald_on_record|autonomy_supportive|unclear",
      "example_before": "<kutipan/parafrase dekat dari catatan orang tua, atau null>",
      "example_after": "<versi non-controlling-nya, atau null>"
    },
    "data_confidence": "<gunakan nilai confidence yang sudah diberikan di atas apa adanya — JANGAN dihitung ulang sendiri>",
    "key_insight": "<1 kalimat pendek tentang pola atau asumsi yang mungkin ada di cara orang tua memandang situasi ini, disampaikan sebagai kemungkinan untuk direnungkan — bukan sebagai penilaian, dan bukan klaim tentang apa yang sebenarnya dirasakan anak>"
  }
}

Aturan:
- Fokus pada pola lintas beberapa catatan, bukan satu kejadian tunggal.
- Perlakukan catatan orang tua sebagai satu sisi cerita, bukan kebenaran objektif tentang anak.
- Catatan yang ditandai [general] adalah sinyal LEMAH, bukan sinyal kosong. Jangan jadikan catatan [general] sebagai dasar utama sebuah "pola" atau key_insight — tapi tetap boleh disebut sebagai konteks. Dasarkan klaim pola terutama pada catatan [spesifik].
- Kalau data_confidence yang diberikan adalah "low" (entah karena jumlah catatan sedikit, atau sebagian besar masih [general]), JANGAN klaim adanya pola yang kuat. Cukup deskripsikan apa yang ada secara ringan, dan biarkan patterns kosong atau minimal kalau memang datanya belum cukup untuk itu.
- JANGAN PERNAH mendeskripsikan perasaan, niat, atau sudut pandang anak sebagai fakta — kamu hanya punya cerita orang tua tentang anak, bukan cerita dari anak itu sendiri. Kalau perlu menyinggung kemungkinan perspektif anak, gunakan frasa seperti "anak mungkin merasa..., meski ini belum dikonfirmasi dari sisi anak."
- ${CAUTIOUS_LANGUAGE_RULE_ID}
- ${AUTONOMY_SUPPORTIVE_RULE_ID}
- ${DATA_NOT_JUDGMENT_RULE_ID}
- ${personalityRuleId(name)} (berlaku untuk summary dan key_insight)
- ${QUOTE_RULE_ID}
- Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.`;
}

export const PARENT_ONLY_OVERVIEW_JSON_SCHEMA = {
  name: "parent_only_overview",
  schema: {
    type: "object",
    properties: {
      overview: {
        type: "object",
        properties: {
          headline: { type: "string" },
          summary: { type: "string" },
          patterns: {
            type: "array",
            items: {
              type: "object",
              properties: {
                topic: { type: "string" },
                observation: { type: "string" },
                suggested_approach: { type: "string" },
              },
              required: ["topic", "observation", "suggested_approach"],
              additionalProperties: false,
            },
          },
          parent_signal: {
            type: "object",
            properties: {
              frustration_level: { type: "string", enum: ["low", "moderate", "high"] },
              reflection_depth: { type: "string", enum: ["surface", "building", "specific"] },
            },
            required: ["frustration_level", "reflection_depth"],
            additionalProperties: false,
          },
          communication_style: {
            type: "object",
            properties: {
              detected_pattern: { type: "string", enum: ["bald_on_record", "autonomy_supportive", "unclear"] },
              example_before: { type: ["string", "null"] },
              example_after: { type: ["string", "null"] },
            },
            required: ["detected_pattern", "example_before", "example_after"],
            additionalProperties: false,
          },
          data_confidence: { type: "string", enum: ["low", "building", "high"] },
          key_insight: { type: "string" },
        },
        required: [
          "headline",
          "summary",
          "patterns",
          "parent_signal",
          "communication_style",
          "data_confidence",
          "key_insight",
        ],
        additionalProperties: false,
      },
    },
    required: ["overview"],
    additionalProperties: false,
  },
};
