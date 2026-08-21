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
    Sertakan TEPAT satu kalimat dalam tanda kutip ganda — kalimat spesifik yang bisa diucapkan orang tua ke anak, casual dan hangat kayak orang tua asli ngomong ("aku"/"kamu", boleh "nak"/"sayang"/"mama tau"), BUKAN bahasa formal ("saya"/"Anda"). Sisanya tetap tanpa kutip — jangan bungkus seluruh jawabanmu dalam tanda kutip.
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

    static func overviewPrompt(_ data: DummyDataset) -> String {
        """
        Kamu adalah asisten keluarga yang empatik. Tugasmu menggabungkan catatan emosi anak dengan konteks dari orang tua menjadi ringkasan hubungan yang hati-hati dan tidak menghakimi. Tujuannya membantu orang tua memahami perspektif anaknya dengan lebih berempati.

        Catatan emosi anak (minggu terakhir):
        \(compactLogs(data))

        Konteks dari orang tua (interaksi terakhir dan refleksi):
        \(compactParentContext(data))

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
        - \(cautiousLanguageRule)
        - \(personalityRule(childName: firstName(data.child.name))) (berlaku untuk summary dan key_insight)
        - \(quoteRule)
        - Pertimbangkan perspektif anak maupun orang tua.
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

    static func prompt(for task: BenchmarkTask, data: DummyDataset) -> String {
        switch task {
        case .extraction: return extractionPrompt(for: representativeLog(data))
        case .howToReact: return howToReactPrompt(for: representativeLog(data), childName: firstName(data.child.name))
        case .overview: return overviewPrompt(data)
        case .reflection: return reflectionPrompt(data)
        }
    }
}
