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

export function buildOverviewPrompt(
  logs: EmotionLogForPrompt[],
  interactions: ParentInteractionForPrompt[],
  reflections: ParentReflectionForPrompt[],
  childName: string,
): string {
  const name = firstName(childName);
  return `Kamu adalah asisten keluarga yang empatik. Tugasmu menggabungkan catatan emosi anak dengan konteks dari orang tua menjadi ringkasan hubungan yang hati-hati dan tidak menghakimi, DAN memberi penyesuaian komunikasi yang konkret, spesifik, dan low-effort untuk minggu ini. Tujuannya membantu orang tua memahami perspektif anaknya dengan lebih berempati, dan pindah dari nasihat satu arah ke memvalidasi perasaan anak dulu.

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
    "key_insight": "<1 kalimat pendek yang menghubungkan perspektif orang tua dan anak sebagai kemungkinan, bukan fakta>"
  }
}

Aturan:
- Fokus pada pola lintas beberapa catatan, bukan satu kejadian tunggal.
- Perlakukan catatan emosi sebagai sinyal, bukan kebenaran objektif.
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
          key_insight: { type: "string" },
        },
        required: ["headline", "summary", "patterns", "relationship_signal", "communication_style", "key_insight"],
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
  has_cognitive_mechanism: boolean;
  followup_question: string | null;
  crisis_signal: boolean;
}

const COGNITIVE_MECHANISM_RULE_ID =
  `"Cognitive mechanism words" adalah kata-kata sebab-akibat (karena, sebab, gara-gara, makanya, akibatnya) atau kata pemahaman/insight (jadi sadar, baru ngeh, ternyata, jadi paham, jadi ngerti, akhirnya nyadar) yang nunjukin penulis udah mikirin KENAPA sesuatu terjadi, bukan cuma nyebutin APA yang terjadi/dirasain. \
Contoh TANPA cognitive mechanism words (masih dangkal, cuma nyebut perasaan): "Aku capek banget hari ini." / "Hari ini seru sih." \
Contoh DENGAN cognitive mechanism words (udah ada penjelasan/pemahaman): "Aku capek banget hari ini karena kerjaan numpuk terus deadline-nya maju." / "Hari ini seru soalnya akhirnya ketemu temen lama, jadi baru sadar aku kangen banget."`;

export function buildFollowupEvaluationPrompt(
  questionText: string,
  answerText: string,
): string {
  return `Kamu membantu mengevaluasi jawaban dari sebuah guided journal (catatan reflektif harian).

Pertanyaan yang diajukan:
"${questionText}"

Jawaban orang yang mengisi:
"${answerText}"

${COGNITIVE_MECHANISM_RULE_ID}

Tugas 1 — Evaluasi:
Tentukan apakah jawaban di atas SUDAH mengandung cognitive mechanism words (sebab-akibat/insight) atau BELUM.

Tugas 2 — Follow-up (hanya jika Tugas 1 = belum ada):
Kalau jawabannya masih dangkal (belum ada cognitive mechanism words), buat SATU pertanyaan follow-up singkat dan casual (bukan formal, bahasa sehari-hari Indonesia) yang ngajak orangnya cerita lebih jauh soal "kenapa" atau "apa yang bikin gitu" — spesifik nyambung ke jawaban dia, bukan pertanyaan generik "kenapa?" doang. Kalau jawaban SUDAH mengandung cognitive mechanism words, isi null di sini — jangan tetap kasih pertanyaan.

Tugas 3 — Sinyal krisis:
Tandai true HANYA jika jawaban menunjukkan indikasi serius menyakiti diri sendiri, keinginan bunuh diri, atau bahaya langsung terhadap keselamatan. Jangan tandai true untuk emosi negatif biasa (capek, sedih, stres) — hanya untuk sinyal krisis yang jelas.

Output HARUS JSON valid, tanpa markdown, persis bentuk ini:
{
  "has_cognitive_mechanism": true or false,
  "followup_question": "<pertanyaan follow-up singkat, atau null kalau has_cognitive_mechanism true>",
  "crisis_signal": true or false
}`;
}

export const FOLLOWUP_EVALUATION_JSON_SCHEMA = {
  name: "followup_evaluation",
  schema: {
    type: "object",
    properties: {
      has_cognitive_mechanism: { type: "boolean" },
      followup_question: { type: ["string", "null"] },
      crisis_signal: { type: "boolean" },
    },
    required: ["has_cognitive_mechanism", "followup_question", "crisis_signal"],
    additionalProperties: false,
  },
};
