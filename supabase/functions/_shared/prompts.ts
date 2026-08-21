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

export interface OverviewResult {
  overview: {
    headline: string;
    summary: string;
    patterns: { topic: string; observation: string }[];
    relationship_signal: {
      parent_concern: "low" | "moderate" | "high";
      child_openness: "low" | "moderate" | "high";
      possible_misalignment: boolean;
    };
    key_insight: string;
  };
}

export function buildOverviewPrompt(
  logs: EmotionLogForPrompt[],
  interactions: ParentInteractionForPrompt[],
  reflections: ParentReflectionForPrompt[],
  childName: string,
): string {
  const name = firstName(childName);
  return `Kamu adalah asisten keluarga yang empatik. Tugasmu menggabungkan catatan emosi anak dengan konteks dari orang tua menjadi ringkasan hubungan yang hati-hati dan tidak menghakimi. Tujuannya membantu orang tua memahami perspektif anaknya dengan lebih berempati.

Catatan emosi anak (minggu terakhir):
${compactLogs(logs)}

Konteks dari orang tua (interaksi terakhir dan refleksi):
${compactParentContext(interactions, reflections)}

Buat ringkasan terstruktur sebagai JSON saja, persis bentuk ini:

{
  "overview": {
    "headline": "<1 kalimat pendek, maks 10 kata, hati-hati>",
    "summary": "<1-2 kalimat singkat tentang pola keseluruhan, hati-hati>",
    "patterns": [
      { "topic": "Pendidikan|Pertemanan|Keluarga|Lainnya", "observation": "<1 kalimat pendek, hati-hati>" }
    ],
    "relationship_signal": {
      "parent_concern": "low|moderate|high",
      "child_openness": "low|moderate|high",
      "possible_misalignment": true
    },
    "key_insight": "<1 kalimat pendek yang menghubungkan perspektif orang tua dan anak sebagai kemungkinan, bukan fakta>"
  }
}

Aturan:
- Fokus pada pola lintas beberapa catatan, bukan satu kejadian tunggal.
- Perlakukan catatan emosi sebagai sinyal, bukan kebenaran objektif.
- ${CAUTIOUS_LANGUAGE_RULE_ID}
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
              },
              required: ["topic", "observation"],
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
          key_insight: { type: "string" },
        },
        required: ["headline", "summary", "patterns", "relationship_signal", "key_insight"],
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
