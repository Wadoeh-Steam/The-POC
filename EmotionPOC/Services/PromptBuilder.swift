import Foundation

/// Real production LLM touchpoints (ARCHITECTURE.md §4) — not the Phase 0
/// POC's original `summary` task, which isn't part of the shipped product
/// (only `overview`/`reflection`/`how-to-react`/extraction are). Swift is
/// the reference spec for on-device mode (§2a); the TS copy lives in
/// `supabase/functions/_shared/prompts.ts` — keep both in sync.
enum BenchmarkTask: String, CaseIterable, Identifiable, Codable, Hashable {
    case extraction
    case howToReact
    case overview
    case reflection

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extraction: return "Context Extraction (+ crisis signal)"
        case .howToReact: return "How-to-React Tip"
        case .overview: return "Relationship Overview"
        case .reflection: return "Reflection Recommendations"
        }
    }
}

enum LogContextField: String, CaseIterable, Codable {
    case feeling = "FEELING"
    case trigger = "TRIGGER"
    case perceivedCause = "PERCEIVED_CAUSE"
    case priorEffort = "PRIOR_EFFORT"
    case futurePlan = "FUTURE_PLAN"
    case expectedOutcome = "EXPECTED_OUTCOME"

    /// Indonesian label used inline in the compact log representation.
    var indonesianLabel: String {
        switch self {
        case .feeling: return "perasaan"
        case .trigger: return "pemicu"
        case .perceivedCause: return "dugaan penyebab"
        case .priorEffort: return "usaha yang sudah dilakukan"
        case .futurePlan: return "rencana ke depan"
        case .expectedOutcome: return "harapan hasil"
        }
    }
}

enum PromptBuilder {

    // MARK: - Valence classification

    /// Mirrors the Postgres generated column in
    /// `supabase/migrations/20260814000001_initial_schema.sql` — same
    /// placeholder thresholds, same "not finalized" caveat (ARCHITECTURE.md §3, §7).
    static func valenceClassification(_ valence: Double) -> String {
        switch valence {
        case let v where v >= 0.5: return "positive"
        case let v where v >= 0.15: return "slightlyPositive"
        case let v where v > -0.15: return "neutral"
        case let v where v > -0.5: return "slightlyNegative"
        default: return "negative"
        }
    }

    /// First name only — "Maya Anderson" reads formal/clinical in a warm
    /// personal-address sentence ("aku tahu momen kayak gini sama Maya
    /// Anderson..."), "Maya" reads like how a person would actually say it.
    static func firstName(_ fullName: String) -> String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }

    // MARK: - Compact representations
    // Deliberately cites valence_classification, not the raw float — every
    // prompt below instructs the model not to cite raw numbers, so the
    // compact representation shouldn't hand it one either.

    static func compactLog(_ log: EmotionLog, contextAnswers: [LogContextField: String] = [:]) -> String {
        var parts: [String] = [
            String(log.timestamp.prefix(10)),
            "suasana=\(valenceClassification(log.healthkit.valence))",
        ]
        if !log.healthkit.labels.isEmpty {
            parts.append("label=[\(log.healthkit.labels.joined(separator: ","))]")
        }
        if !log.healthkit.associations.isEmpty {
            parts.append("konteks=[\(log.healthkit.associations.joined(separator: ","))]")
        }
        if let journal = log.journal, !journal.isEmpty {
            parts.append("catatan=\"\(journal)\"")
        }
        for field in LogContextField.allCases {
            if let answer = contextAnswers[field] {
                parts.append("\(field.indonesianLabel)=\"\(answer)\"")
            }
        }
        return "- " + parts.joined(separator: " | ")
    }

    static func compactLogs(_ data: DummyDataset) -> String {
        data.emotionLogs.map { compactLog($0) }.joined(separator: "\n")
    }

    static func compactParentContext(_ data: DummyDataset) -> String {
        var lines: [String] = []
        for i in data.parentContext.recentInteractions {
            lines.append("- \(String(i.timestamp.prefix(10))) [\(i.topic)] \"\(i.interaction)\" (perasaan orang tua: \(i.parentEmotion))")
        }
        if !data.parentContext.parentLogs.isEmpty {
            lines.append("Catatan refleksi orang tua:")
            for p in data.parentContext.parentLogs {
                lines.append("- \(String(p.timestamp.prefix(10))) merasa \(p.emotion): \"\(p.note)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let cautiousLanguageRule = """
    Gunakan bahasa hati-hati saja: "mungkin", "tampaknya", "kemungkinan polanya adalah", "bisa jadi menunjukkan". \
    Jangan pernah gunakan: "mengalami gangguan", "depresi", "ini membuktikan bahwa". \
    Jangan mendiagnosis. Jangan menyalahkan salah satu pihak (anak atau orang tua).
    """

    /// Persona: assertive in DELIVERY/confidence, not in the claims made —
    /// cautiousLanguageRule (hedging on what's actually happening with the
    /// child) is a safety guardrail, not something this persona overrides.
    /// "Tegas" here means she sounds sure of her own advice, not that she
    /// asserts diagnoses.
    ///
    /// Explicit addressee rule added after observing a real bug
    /// (2026-08-20): the model opened a tip with "Maya, aku tahu momen
    /// kayak gini sama Maya..." — addressing the CHILD directly by name as
    /// a vocative, then immediately referring to her in third person in
    /// the same breath. The narrative is always parent-facing; only an
    /// explicit quoted script (quoteRule) should switch to addressing the
    /// child.
    /// Kept deliberately terse — the English mirror's equivalent plus a
    /// full log history blew past FoundationModels' 4096-token context
    /// window at a more verbose wording (observed live, 2026-08-20).
    /// OpenRouter has generous limits so this wasn't strictly forced here,
    /// but kept in sync anyway.
    private static func personalityRule(childName: String) -> String {
        """
        Kamu pendamping keluarga bijaksana usia 50-an — tegas dan percaya diri, bukan ragu-ragu atau klinis. Validasi juga perasaan orang tua. Sebut \(childName) di TENGAH kalimat, JANGAN sebagai sapaan pembuka ("\(childName), ...") — kamu bicara KEPADA orang tua TENTANG \(childName), bukan kepada \(childName) langsung (kecuali di dalam kutipan skrip di bawah, di situ boleh menyapa anak).
        """
    }

    /// HumanReadable.swift's QuoteAwareText splits on `"..."` and renders
    /// each quoted span as its own highlighted block, separate from the
    /// surrounding paragraph — this is what makes that split meaningful:
    /// the model already tends to quote suggested dialogue naturally, this
    /// just makes it consistent and intentional.
    private static let quoteRule = """
    Sertakan TEPAT satu kalimat lengkap (bukan potongan 2-3 kata) dalam tanda kutip ganda — kalimat spesifik yang bisa diucapkan orang tua ke anak, casual dan hangat kayak orang tua asli ngomong ("aku"/"kamu", boleh "nak"/"sayang"/"mama tau"), BUKAN bahasa formal ("saya"/"Anda"). Sisanya tetap tanpa kutip — jangan bungkus seluruh jawabanmu dalam tanda kutip.
    """

    /// Self-Determination Theory, translated into a concrete rule the model
    /// can follow: acknowledge the child's feeling BEFORE the parent's own
    /// perspective, prefer language that leaves the child a choice over
    /// direct commands. "Bald-on-record speech" (Brown & Levinson) is
    /// screened for in the parent's own logged interactions. Decision to
    /// move the overview from purely descriptive to this more directive
    /// coaching format: 2026-08-25 — see context.md, supersedes the
    /// earlier "stays descriptive" call. Kept in sync with prompts.ts's
    /// AUTONOMY_SUPPORTIVE_RULE_ID.
    private static let autonomySupportiveRule = """
    Untuk "suggested_approach" dan "communication_style": dasarkan pada Self-Determination Theory — anak perlu merasa otonom (bukan dikontrol), bukan berarti dibiarkan tanpa arahan. Prinsip utama: akui dulu perasaan anak secara eksplisit SEBELUM masuk ke perspektif/harapan orang tua — jangan langsung kasih nasihat satu arah. Kalau di catatan interaksi orang tua ada kalimat yang sifatnya perintah langsung/bald-on-record (menyerang otonomi anak — misal "kamu harus...", "pokoknya kamu wajib...", "jangan bantah, lakukan aja"), set detected_pattern = "bald_on_record", kutip kalimat aslinya (atau parafrase dekat) di example_before, dan tulis versi non-controlling-nya di example_after — ganti perintah langsung jadi kalimat yang kasih ruang pilihan (contoh: "kamu harus beresin kamar sekarang" -> "mungkin lebih enak kalau kamarnya dirapiin sebelum makan malam, gimana?"). Kalau nggak ada indikasi jelas di data yang ada, detected_pattern = "unclear" — JANGAN memaksakan contoh yang tidak benar-benar ada di catatan — dan example_before/example_after diisi null.
    """

    /// Parents are naturally invested and struggle to evaluate their own
    /// choices objectively, and in high power-distance cultures (Indonesia's
    /// PDI = 78) tend to default to demanding obedience when they feel
    /// judged. Framing as "pola yang tercatat" rather than "kamu selalu..."
    /// routes around that defensive reaction. Kept in sync with prompts.ts's
    /// DATA_NOT_JUDGMENT_RULE_ID.
    private static let dataNotJudgmentRule = """
    Sajikan setiap "observation" sebagai POLA DARI DATA yang tercatat, bukan penilaian ke orang tua. Bukan "kamu terlalu memaksa soal beres-beres", tapi "pola yang tercatat: percakapan soal beres-beres di hari Kamis cenderung diikuti penurunan mood anak". Kalau ada pola waktu/hari/topik yang jelas kelihatan dari data, sebutkan spesifik (hari, topik) — itu yang bikin suggested_approach kerasa actionable, bukan generik. Jangan mengarang pola yang tidak benar-benar didukung datanya.
    """

    // MARK: - 1. Extraction + crisis-signal check (check-log-context, ARCHITECTURE.md §3a, §2b)

    static func extractionPrompt(for log: EmotionLog) -> String {
        """
        Kamu membantu memproses catatan emosi harian yang ditulis oleh seorang anak/remaja.

        Anak menulis catatan berikut (jika ada teks bebas):
        "\(log.journal ?? "(tidak ada teks, hanya pilihan cepat)")"

        Info tambahan dari pilihan cepat: label=[\(log.healthkit.labels.joined(separator: ","))], konteks=[\(log.healthkit.associations.joined(separator: ","))]

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
        }
        """
    }

    // MARK: - 2. How-to-react tip (generate-how-to-react) 
    // Plain LLM, no RAG/trusted-source grounding — deferred, see PLAN.md Phase 5.

    static func howToReactPrompt(for log: EmotionLog, childName: String) -> String {
        """
        Kamu adalah asisten yang membantu orang tua memahami dan merespons catatan emosi anaknya dengan empati.

        Anak (nama: \(childName)) baru saja mencatat:
        \(compactLog(log))

        Tulis SATU tip singkat (maksimal 2 kalimat, bahasa Indonesia, plain text tanpa markdown) untuk orang tua tentang bagaimana sebaiknya merespons momen ini. \(cautiousLanguageRule) \(personalityRule(childName: childName)) \(quoteRule)

        Fokus pada nada dan pendekatan (misal: dengarkan dulu tanpa menghakimi, tanyakan tanpa memaksa), bukan solusi teknis. Jangan berikan saran medis atau psikologis spesifik.
        """
    }

    // MARK: - 3. Relationship Overview (generate-overview)

    // Wrapper types, not extensions of EmotionLog/RecentInteraction/ParentLog
    // — those are shared with compactLog/compactParentContext above, which
    // don't need [spesifik]/[general] tagging. Kept in sync with
    // prompts.ts's TaggedEmotionLogForPrompt/TaggedParentInteractionForPrompt/
    // TaggedParentReflectionForPrompt.
    struct TaggedEmotionLog {
        let log: EmotionLog
        let isSpecific: Bool
    }

    struct TaggedParentInteraction {
        let interaction: RecentInteraction
        let isSpecific: Bool
    }

    struct TaggedParentReflection {
        let reflection: ParentLog
        let isSpecific: Bool
    }

    /// Placeholder tier thresholds — not tuned/validated, same "not
    /// finalized" caveat as valenceClassification's placeholder thresholds.
    /// Kept in sync with prompts.ts's deriveConfidenceTier.
    static func deriveConfidenceTier(entryCount: Int, specificEntryCount: Int) -> String {
        if entryCount == 0 { return "low" }
        let specificRatio = Double(specificEntryCount) / Double(entryCount)
        if entryCount >= 3 && specificRatio >= 0.5 { return "high" }
        if entryCount >= 2 && specificRatio >= 0.25 { return "building" }
        return "low"
    }

    static func compactLogsTagged(_ entries: [TaggedEmotionLog]) -> String {
        entries.map { entry in
            let tag = entry.isSpecific ? "spesifik" : "general"
            let rest = compactLog(entry.log).dropFirst(2)
            return "- [\(tag)] \(rest)"
        }.joined(separator: "\n")
    }

    static func compactParentContextTagged(
        interactions: [TaggedParentInteraction],
        reflections: [TaggedParentReflection]
    ) -> String {
        var lines: [String] = []
        for t in interactions {
            let tag = t.isSpecific ? "spesifik" : "general"
            lines.append("- [\(tag)] \(String(t.interaction.timestamp.prefix(10))) [\(t.interaction.topic)] \"\(t.interaction.interaction)\" (perasaan orang tua: \(t.interaction.parentEmotion))")
        }
        if !reflections.isEmpty {
            lines.append("Catatan refleksi orang tua:")
            for t in reflections {
                let tag = t.isSpecific ? "spesifik" : "general"
                lines.append("- [\(tag)] \(String(t.reflection.timestamp.prefix(10))) merasa \(t.reflection.emotion): \"\(t.reflection.note)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func overviewPrompt(
        logs: [TaggedEmotionLog],
        interactions: [TaggedParentInteraction],
        reflections: [TaggedParentReflection],
        childName: String,
        childConfidenceTier: String,
        parentConfidenceTier: String
    ) -> String {
        let name = firstName(childName)
        let childSpecificCount = logs.filter(\.isSpecific).count
        let parentEntryCount = interactions.count + reflections.count
        let parentSpecificCount = interactions.filter(\.isSpecific).count + reflections.filter(\.isSpecific).count
        return """
        Kamu adalah asisten keluarga yang empatik. Tugasmu menggabungkan catatan emosi anak dengan konteks dari orang tua menjadi ringkasan hubungan yang hati-hati dan tidak menghakimi, DAN memberi penyesuaian komunikasi yang konkret, spesifik, dan low-effort untuk minggu ini. Tujuannya membantu orang tua memahami perspektif anaknya dengan lebih berempati, dan pindah dari nasihat satu arah ke memvalidasi perasaan anak dulu.

        Data minggu ini:
        - Anak: \(logs.count) catatan, \(childSpecificCount) di antaranya spesifik. Confidence: \(childConfidenceTier).
        - Orang tua: \(parentEntryCount) catatan, \(parentSpecificCount) di antaranya spesifik. Confidence: \(parentConfidenceTier).

        Catatan emosi anak (minggu terakhir, ditandai [spesifik] atau [general] per catatan):
        \(compactLogsTagged(logs))
        Konteks dari orang tua (interaksi terakhir dan refleksi, ditandai [spesifik] atau [general] per catatan):
        \(compactParentContextTagged(interactions: interactions, reflections: reflections))

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
        - Fokus pada pola lintas beberapa catatan, bukan satu kejadian tunggal.
        - Perlakukan catatan emosi sebagai sinyal, bukan kebenaran objektif.
        - Catatan yang ditandai [general] adalah sinyal LEMAH, bukan sinyal kosong. Jangan jadikan catatan [general] sebagai dasar utama sebuah "pola" — tapi tetap boleh disebut sebagai konteks. Dasarkan klaim pola terutama pada catatan [spesifik].
        - Kalau data_confidence.child adalah "low" — biasanya karena catatan anak minggu ini cuma 1-2 kali, atau sebagian besar [general] — JANGAN klaim adanya "pola" dari sisi anak. Cukup deskripsikan apa yang ada apa adanya (misal "baru ada satu catatan minggu ini, belum cukup untuk melihat pola"), dan child_openness/possible_misalignment harus mencerminkan keterbatasan ini, bukan disimpulkan seolah datanya lengkap.
        - \(cautiousLanguageRule)
        - \(autonomySupportiveRule)
        - \(dataNotJudgmentRule)
        - \(personalityRule(childName: name)) (berlaku untuk summary dan key_insight)
        - \(quoteRule)
        - Pertimbangkan perspektif anak maupun orang tua.
        - Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.
        """
    }

    // MARK: - 3b. Parent-only overview (be1, parent-side-only path)
    // Distinct from overviewPrompt above: runs when there's no child data
    // yet — model only sees the parent's own guided-journal entries and
    // must never assert the child's feelings/perspective as fact.
    // entries/confidenceTier are computed by the caller and passed in as-is.
    // Not wired into DummyDataset/BenchmarkTask yet — that needs fixture
    // data for parent guided-journal entries, which this POC dataset
    // doesn't have. Kept in sync with prompts.ts's buildParentOnlyOverviewPrompt.

    struct ParentLogAnswerForPrompt {
        let field: LogContextField
        let questionText: String
        let answerText: String
    }

    struct ParentLogEntryForPrompt {
        let timestamp: String
        let isSpecific: Bool
        let answers: [ParentLogAnswerForPrompt]
    }

    static func compactParentLogEntries(_ entries: [ParentLogEntryForPrompt]) -> String {
        entries.map { entry in
            let tag = entry.isSpecific ? "[spesifik]" : "[general]"
            let qa = entry.answers
                .map { "\($0.field.indonesianLabel): \"\($0.questionText)\" -> \"\($0.answerText)\"" }
                .joined(separator: " | ")
            return "- \(String(entry.timestamp.prefix(10))) \(tag) \(qa)"
        }.joined(separator: "\n")
    }

    static func parentOnlyOverviewPrompt(
        entries: [ParentLogEntryForPrompt],
        childName: String,
        confidenceTier: String
    ) -> String {
        let name = firstName(childName)
        let specificCount = entries.filter(\.isSpecific).count
        return """
        Kamu adalah pelatih pribadi yang empatik untuk orang tua. Tugasmu menganalisis catatan refleksi orang tua sendiri (minggu ini) untuk membantu mereka membangun kosakata emosi dan pola komunikasi yang lebih autonomy-supportive — SEBELUM mereka mempraktikkannya ke anak. Kamu TIDAK punya data dari anak sama sekali di tahap ini, jadi jangan pernah membuat klaim atau tebakan pasti tentang perasaan atau sudut pandang anak.

        Data minggu ini: \(entries.count) catatan orang tua, \(specificCount) di antaranya spesifik (mengandung kata sebab-akibat/insight). Confidence level minggu ini: \(confidenceTier).

        Catatan refleksi orang tua (minggu ini, ditandai [spesifik] atau [general] per catatan):
        \(compactParentLogEntries(entries))

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
        - \(cautiousLanguageRule)
        - \(autonomySupportiveRule)
        - \(dataNotJudgmentRule)
        - \(personalityRule(childName: name)) (berlaku untuk summary dan key_insight)
        - \(quoteRule)
        - Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.
        """
    }

    // MARK: - 4. Reflection Recommendations (generate-reflection, MVP2)

    static func reflectionPrompt(_ data: DummyDataset) -> String {
        """
        Kamu adalah asisten keluarga yang empatik. Berdasarkan seluruh riwayat catatan emosi anak dan konteks orang tua, berikan rekomendasi refleksi untuk membantu orang tua terhubung lebih baik dengan anaknya.

        Seluruh riwayat catatan emosi anak:
        \(compactLogs(data))

        Konteks dari orang tua:
        \(compactParentContext(data))

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
        - \(cautiousLanguageRule)
        - \(personalityRule(childName: firstName(data.child.name))) (berlaku untuk description)
        - \(quoteRule)
        - Output harus JSON valid saja, tanpa markdown, tanpa komentar tambahan.
        """
    }

    // MARK: - Dispatch

    /// `extraction`/`howToReact` operate on a single representative entry
    /// (the first one with journal text, for a realistic non-empty test)
    /// rather than the whole dataset — mirrors how those two touchpoints
    /// actually work in production (per-log, not per-family).
    static func representativeLog(_ data: DummyDataset) -> EmotionLog {
        data.emotionLogs.first(where: { $0.journal?.isEmpty == false }) ?? data.emotionLogs[0]
    }

    /// Adapts the benchmark's DummyDataset (no isSpecific/confidence fields
    /// in the fixture) to overviewPrompt's tagged params. isSpecific is
    /// placeholder-false throughout — same caveat as generate-overview's
    /// TS caller, no has_cognitive_mechanism classifier exists yet.
    static func overviewPrompt(_ data: DummyDataset) -> String {
        let taggedLogs = data.emotionLogs.map { TaggedEmotionLog(log: $0, isSpecific: false) }
        let taggedInteractions = data.parentContext.recentInteractions.map {
            TaggedParentInteraction(interaction: $0, isSpecific: false)
        }
        let taggedReflections = data.parentContext.parentLogs.map {
            TaggedParentReflection(reflection: $0, isSpecific: false)
        }
        return overviewPrompt(
            logs: taggedLogs,
            interactions: taggedInteractions,
            reflections: taggedReflections,
            childName: firstName(data.child.name),
            childConfidenceTier: deriveConfidenceTier(entryCount: taggedLogs.count, specificEntryCount: 0),
            parentConfidenceTier: deriveConfidenceTier(
                entryCount: taggedInteractions.count + taggedReflections.count,
                specificEntryCount: 0
            )
        )
    }

    static func prompt(for task: BenchmarkTask, data: DummyDataset) -> String {
        switch task {
        case .extraction: return extractionPrompt(for: representativeLog(data))
        case .howToReact: return howToReactPrompt(for: representativeLog(data), childName: firstName(data.child.name))
        case .overview: return overviewPrompt(data)
        case .reflection: return reflectionPrompt(data)
        }
    }
}
