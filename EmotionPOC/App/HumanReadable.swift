import SwiftUI

/// Plain-Indonesian presentation layer for ContentView — the audience for
/// these comparisons is non-technical (parents/stakeholders, not
/// developers), so raw JSON, English task names, and HealthKit's English
/// mood vocabulary all need a human-readable pass before they're shown.
/// Purely cosmetic: reads the same data PromptBuilder.swift feeds the
/// model, doesn't change what's tested.
enum HumanLabels {
    static func moodLabel(_ raw: String) -> String {
        switch raw {
        case "amused": return "Terhibur"
        case "annoyed": return "Jengkel"
        case "calm": return "Tenang"
        case "discouraged": return "Putus Asa"
        case "excited": return "Bersemangat"
        case "frustrated": return "Frustrasi"
        case "happy": return "Senang"
        case "hopeful": return "Berharap"
        case "indifferent": return "Acuh Tak Acuh"
        case "irritated": return "Kesal"
        case "lonely": return "Kesepian"
        case "overwhelmed": return "Kewalahan"
        case "proud": return "Bangga"
        case "sad": return "Sedih"
        case "stressed": return "Stres"
        case "worried": return "Khawatir"
        default: return raw.capitalized
        }
    }

    static func associationLabel(_ raw: String) -> String {
        switch raw {
        case "education": return "Pendidikan"
        case "family": return "Keluarga"
        case "friends": return "Pertemanan"
        case "tasks": return "Tugas"
        default: return raw.capitalized
        }
    }

    static func valence(_ v: Double) -> (emoji: String, label: String, color: Color) {
        switch PromptBuilder.valenceClassification(v) {
        case "positive": return ("😊", "Positif", .green)
        case "slightlyPositive": return ("🙂", "Agak Positif", .green)
        case "neutral": return ("😐", "Netral", .gray)
        case "slightlyNegative": return ("😕", "Agak Negatif", .orange)
        default: return ("😢", "Negatif", .red)
        }
    }

    static func dateLabel(_ iso: String) -> String {
        let datePart = String(iso.prefix(10))
        let comps = datePart.split(separator: "-")
        guard comps.count == 3, let y = Int(comps[0]), let m = Int(comps[1]), let d = Int(comps[2]), m >= 1, m <= 12 else {
            return datePart
        }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"]
        return "\(d) \(months[m]) \(y)"
    }

    static func levelLabel(_ raw: String) -> String {
        switch raw {
        case "low": return "Rendah"
        case "moderate": return "Sedang"
        case "high": return "Tinggi"
        default: return raw.capitalized
        }
    }

    static func taskName(_ task: BenchmarkTask) -> String {
        switch task {
        case .extraction: return "Analisis Catatan Anak"
        case .howToReact: return "Tips untuk Orang Tua"
        case .overview: return "Ringkasan Hubungan"
        case .reflection: return "Rekomendasi Refleksi"
        }
    }

    static func taskDescription(_ task: BenchmarkTask) -> String {
        switch task {
        case .extraction: return "Membaca satu catatan emosi anak dan mengecek apakah ada tanda krisis yang perlu perhatian segera."
        case .howToReact: return "Memberi satu saran singkat ke orang tua tentang cara merespons catatan anak dengan baik."
        case .overview: return "Merangkum pola dari beberapa catatan anak menjadi gambaran hubungan yang mudah dipahami."
        case .reflection: return "Memberi beberapa rekomendasi refleksi untuk orang tua berdasarkan seluruh riwayat catatan."
        }
    }
}

// MARK: - Input (what was tested)

struct EmotionLogCard: View {
    let log: EmotionLog

    var body: some View {
        let v = HumanLabels.valence(log.healthkit.valence)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(v.emoji) \(v.label)")
                    .font(.caption.bold())
                    .foregroundStyle(v.color)
                Spacer()
                Text(HumanLabels.dateLabel(log.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            let tags = (log.healthkit.labels.map(HumanLabels.moodLabel) + log.healthkit.associations.map(HumanLabels.associationLabel))
            if !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let journal = log.journal, !journal.isEmpty {
                Text("\u{201C}\(journal)\u{201D}")
                    .font(.caption.italic())
            } else {
                Text("(tidak menulis catatan, hanya pilih mood)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ParentContextView: View {
    let data: DummyDataset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(data.parentContext.recentInteractions, id: \.timestamp) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(HumanLabels.dateLabel(i.timestamp)) · \(i.topic)")
                        .font(.caption2.bold())
                    Text("\u{201C}\(i.interaction)\u{201D}")
                        .font(.caption.italic())
                    Text("Perasaan orang tua saat itu: \(i.parentEmotion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !data.parentContext.parentLogs.isEmpty {
                Text("Catatan refleksi orang tua")
                    .font(.caption.bold())
                    .padding(.top, 4)
                ForEach(data.parentContext.parentLogs, id: \.timestamp) { p in
                    Text("\(HumanLabels.dateLabel(p.timestamp)) — merasa \(p.emotion): \u{201C}\(p.note)\u{201D}")
                        .font(.caption2)
                }
            }
        }
    }
}

struct TaskInputView: View {
    let task: BenchmarkTask
    let data: DummyDataset

    var body: some View {
        switch task {
        case .extraction, .howToReact:
            EmotionLogCard(log: PromptBuilder.representativeLog(data))

        case .overview, .reflection:
            VStack(alignment: .leading, spacing: 8) {
                Text("Semua catatan anak (\(data.emotionLogs.count) entri):")
                    .font(.caption.bold())
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.emotionLogs, id: \.id) { log in
                        EmotionLogCard(log: log)
                    }
                }
                Text("Konteks dari orang tua:")
                    .font(.caption.bold())
                    .padding(.top, 4)
                ParentContextView(data: data)
            }
        }
    }
}

// MARK: - Output (what came back)

enum OutputParser {
    static func stripFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            let firstNewline = t.firstIndex(of: "\n") ?? t.startIndex
            t = String(t[t.index(after: firstNewline)...])
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = stripFences(text).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Splits a field on quoted spans — PromptBuilder.swift's quoteRule asks
/// the model to wrap any suggested line of dialogue in `"..."`, so a
/// parent can tell "here's exactly what to say" apart from the
/// surrounding narrative. Handles straight `"` and curly `“ ”` quotes,
/// since translated/model output isn't guaranteed to use one consistently.
enum QuoteSegment {
    case text(String)
    case quote(String)

    static func parse(_ input: String) -> [QuoteSegment] {
        var segments: [QuoteSegment] = []
        var current = ""
        var quoteBuffer = ""
        var inQuote = false
        for char in input {
            if char == "\"" || char == "\u{201C}" || char == "\u{201D}" {
                if inQuote {
                    let trimmed = quoteBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { segments.append(.quote(trimmed)) }
                    quoteBuffer = ""
                    inQuote = false
                } else {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { segments.append(.text(trimmed)) }
                    current = ""
                    inQuote = true
                }
            } else if inQuote {
                quoteBuffer.append(char)
            } else {
                current.append(char)
            }
        }
        // Unterminated quote (e.g. truncated mid-quote) — fold back into
        // plain text with its opening mark rather than silently dropping it.
        if inQuote {
            current += "\"" + quoteBuffer
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(.text(trimmed)) }
        return segments
    }
}

/// Renders quoted spans as their own highlighted block on a separate line
/// — not inline within the paragraph — so a suggested line of dialogue
/// reads as "say this" rather than blending into the narrative around it.
struct QuoteAwareText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(QuoteSegment.parse(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let t):
                    Text(t)
                case .quote(let q):
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(q)
                            .italic()
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct TaskOutputView: View {
    let task: BenchmarkTask
    let raw: String

    var body: some View {
        Group {
            switch task {
            case .howToReact:
                QuoteAwareText(text: raw)
                    .font(.subheadline)

            case .extraction:
                if let json = OutputParser.decodeObject(raw), let extracted = json["extracted"] as? [String: Any?] {
                    extractionBody(extracted: extracted, crisis: (json["crisis_signal"] as? Bool) ?? false)
                } else {
                    fallback
                }

            case .overview:
                if let json = OutputParser.decodeObject(raw), let overview = json["overview"] as? [String: Any] {
                    overviewBody(overview)
                } else {
                    fallback
                }

            case .reflection:
                if let json = OutputParser.decodeObject(raw), let recs = json["recommendations"] as? [[String: Any]] {
                    reflectionBody(recs)
                } else {
                    fallback
                }
            }
        }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tidak bisa diformat rapi — teks asli:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(raw)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func extractionBody(extracted: [String: Any?], crisis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(LogContextField.allCases, id: \.self) { field in
                let value = (extracted[field.rawValue] ?? nil) as? String
                HStack(alignment: .top, spacing: 6) {
                    Text(field.indonesianLabel.capitalized + ":")
                        .font(.caption.bold())
                    Text(value ?? "— tidak disebutkan —")
                        .font(.caption)
                        .foregroundStyle(value == nil ? .secondary : .primary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: crisis ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                Text(crisis ? "Ada sinyal krisis" : "Tidak ada sinyal krisis")
            }
            .font(.caption.bold())
            .foregroundStyle(crisis ? Color.red : Color.green)
            .padding(.top, 2)
        }
    }

    private func overviewBody(_ overview: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headline = overview["headline"] as? String {
                Text(headline).font(.subheadline.bold())
            }
            if let summary = overview["summary"] as? String {
                QuoteAwareText(text: summary).font(.caption)
            }
            if let patterns = overview["patterns"] as? [[String: Any]], !patterns.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(patterns.enumerated()), id: \.offset) { _, p in
                        if let topic = p["topic"] as? String, let obs = p["observation"] as? String {
                            HStack(alignment: .top, spacing: 4) {
                                Text("•")
                                Text("\(topic): \(obs)")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            if let signal = overview["relationship_signal"] as? [String: Any] {
                HStack(spacing: 10) {
                    if let pc = signal["parent_concern"] as? String {
                        signalBadge("Kekhawatiran ortu", HumanLabels.levelLabel(pc))
                    }
                    if let co = signal["child_openness"] as? String {
                        signalBadge("Keterbukaan anak", HumanLabels.levelLabel(co))
                    }
                }
                if let mis = signal["possible_misalignment"] as? Bool, mis {
                    Text("⚠️ Kemungkinan ada gap pemahaman antara orang tua & anak")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if let insight = overview["key_insight"] as? String {
                QuoteAwareText(text: insight)
                    .font(.caption.italic())
                    .padding(8)
                    .background(Color.yellow.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func signalBadge(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold())
        }
        .padding(6)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func reflectionBody(_ recs: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(recs.enumerated()), id: \.offset) { i, rec in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(i + 1). \(rec["title"] as? String ?? "")")
                        .font(.caption.bold())
                    QuoteAwareText(text: rec["description"] as? String ?? "")
                        .font(.caption)
                    if let basedOn = rec["based_on"] as? String {
                        Text("Berdasarkan: \(basedOn)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Latency, visual comparison

struct LatencyCompareView: View {
    let comparisons: [TaskComparison]

    private var maxMs: Double {
        max(1, comparisons.flatMap { [$0.server?.totalMs, $0.translated?.totalMs].compactMap { $0 } }.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(comparisons) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(HumanLabels.taskName(c.task))
                            .font(.caption.bold())
                        Spacer()
                        if let note = winnerNote(c) {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    bar(label: "Server", ok: c.server?.ok, ms: c.server?.totalMs, color: .blue)
                    bar(label: "On-Device", ok: c.translated?.ok, ms: c.translated?.totalMs, color: .purple)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func winnerNote(_ c: TaskComparison) -> String? {
        guard let s = c.server, s.ok, let t = c.translated, t.ok else { return nil }
        let diff = abs(s.totalMs - t.totalMs)
        if diff < min(s.totalMs, t.totalMs) * 0.1 {
            return "≈ Hampir sama cepat"
        }
        return s.totalMs < t.totalMs ? "🏆 Server lebih cepat" : "🏆 On-Device lebih cepat"
    }

    @ViewBuilder
    private func bar(label: String, ok: Bool?, ms: Double?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .frame(width: 62, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let fraction = ms.map { min($0 / maxMs, 1.0) } ?? 0
                RoundedRectangle(cornerRadius: 4)
                    .fill((ok ?? false) ? color : Color.red.opacity(0.5))
                    .frame(width: geo.size.width * CGFloat(fraction), height: 14)
            }
            .frame(height: 14)
            Text(ms.map { String(format: "%.1f dtk", $0 / 1000) } ?? "—")
                .font(.caption2.monospaced())
                .frame(width: 50, alignment: .trailing)
        }
    }
}
