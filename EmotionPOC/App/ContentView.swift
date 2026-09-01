import SwiftUI
import Translation
import FoundationModels

/// Pairs one task's results from both paths, so the UI can show "this is
/// what went in, this is what came back" side by side instead of two
/// disconnected result lists. Scope is deliberately just these two paths —
/// the raw on-device path (§2a) always fails on Indonesian output and
/// isn't part of what's being compared here; it's still exercised by
/// BenchmarkCLI/CLIEntry.swift for the record (PERFORMANCE_COMPARISON.md §8a).
struct TaskComparison: Identifiable {
    var id: String { task.rawValue }
    let task: BenchmarkTask
    var server: ServerOpenRouter.Result?
    var translated: OnDeviceTranslationPipeline.Result?
}

struct ContentView: View {
    @State private var dataset: DummyDataset?
    @State private var availability: String = "checking..."
    @State private var comparisons: [TaskComparison] = []
    @State private var runningComparison = false
    @State private var runningServerOnly = false
    @State private var console: [String] = []
    // Latest log() line, shown live right under the buttons — added
    // because "Log Teknis" is a collapsed DisclosureGroup by default, so a
    // long-running request (up to 45s per provider attempt, see
    // ServerOpenRouter.generate) had zero visible progress and read as a
    // frozen app (reported live, 2026-08-25).
    @State private var currentStatus: String = ""

    // Stored on-device only (Settings.app-visible UserDefaults, never
    // written to any file in this repo) — a plain tap on the app icon
    // doesn't carry the OPENROUTER_API_KEY env var the way `devicectl -e`
    // does, so server calls silently failed whenever the app wasn't
    // launched from a terminal (observed live, 2026-08-20). This lets
    // testing happen standalone, no relaunch-with-env-var round trip needed.
    @AppStorage("openrouter_api_key") private var storedAPIKey: String = ""
    // Fallback chain when OpenRouter fails (e.g. daily free-tier rate
    // limit — hit live, 2026-08-21): Requesty next (OpenAI-compatible
    // router, "mistral/leanstral-1-5" is its only free model with clean
    // JSON schema support), then Gemini directly as a last resort.
    @AppStorage("requesty_api_key") private var storedRequestyKey: String = ""
    @AppStorage("gemini_api_key") private var storedGeminiKey: String = ""

    private var running: Bool { runningComparison || runningServerOnly }

    // SwiftUI-driven translation test — the ONLY path that can trigger
    // Apple's system download-permission UI for a missing language pack.
    // `OnDeviceTranslator`'s `init(installedSource:target:)` (used in the
    // .task block below) requires the pack to already be installed and
    // can't prompt for it — that's a hard API split, not a bug. This one
    // needs the user to actually tap the button and, if a system sheet
    // appears, approve the download themselves — nothing I can do
    // remotely covers that tap.
    @State private var translationSourceLang: Locale.Language?
    @State private var translationTargetLang: Locale.Language?
    // `.task` can re-fire on a real device even without an obvious view
    // identity change (observed 2026-08-15: --autorun ran the full server
    // pass twice on a physical iPhone) — guard explicitly rather than
    // relying on `.task` only running once.
    @State private var hasAutoRun = false

    private let autoRun = ProcessInfo.processInfo.arguments.contains("--autorun")

    private var isModelAvailable: Bool {
        availability.hasPrefix("SystemLanguageModel.default.availability = available")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Status Model di HP Ini") {
                    HStack(spacing: 6) {
                        Image(systemName: isModelAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isModelAvailable ? .green : .red)
                        Text(isModelAvailable ? "Model on-device siap dipakai" : "Model on-device tidak tersedia di HP ini")
                            .font(.subheadline)
                    }
                    DisclosureGroup("Detail teknis") {
                        Text(availability)
                            .font(.caption2.monospaced())
                    }
                }

                Section("Pengaturan Server") {
                    SecureField("OpenRouter API Key", text: $storedAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Requesty API Key (fallback)", text: $storedRequestyKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Gemini API Key (fallback)", text: $storedGeminiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Tersimpan di HP ini aja. Kalau OpenRouter gagal (misal rate limit harian), otomatis coba Requesty, lalu Gemini.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Pengaturan Awal (sekali saja)") {
                    Button("Install Paket Bahasa Indonesia ↔ Inggris") {
                        translationSourceLang = OnDeviceTranslator.indonesian
                        translationTargetLang = OnDeviceTranslator.english
                    }
                    Text("Perlu dijalankan sekali sebelum tes on-device supaya HP bisa menerjemahkan hasil balik ke Bahasa Indonesia. Mungkin muncul dialog unduh dari sistem.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(runningComparison ? "Sedang Menguji…" : "Mulai Tes Perbandingan") {
                        Task { await runComparison() }
                    }
                    .disabled(running || dataset == nil)
                    Text("Menguji 4 skenario yang sama lewat Server dan lewat HP (on-device), lalu membandingkan kecepatan dan jawabannya.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button(runningServerOnly ? "Sedang Tes Server…" : "Tes Server Saja") {
                        Task { await runServerOnly() }
                    }
                    .disabled(running || dataset == nil)
                    Text("Cuma jalur Server (OpenRouter) — lebih cepat buat cek ulang tanpa nunggu HP (on-device), nggak butuh paket bahasa ter-install.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if running {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(currentStatus.isEmpty ? "Memulai…" : currentStatus)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.top, 2)
                    }
                }

                #if DEBUG
                // Debug-only, no LLM call — seeds the overview card with a
                // hand-written JSON that fills every field of
                // OVERVIEW_JSON_SCHEMA (prompts.ts), so the render path can
                // be checked with no API key / no on-device model needed.
                // Never compiled into a Release build.
                Section {
                    Button("🧪 Muat Contoh Overview (Debug)") {
                        comparisons = [Self.debugSampleOverviewComparison]
                    }
                    Text("Ngisi kartu Ringkasan Hubungan pakai JSON contoh langsung, tanpa manggil LLM — buat mastiin semua field (suggested_approach, communication_style, data_confidence) ke-render bener di layar.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                #endif

                if !comparisons.isEmpty {
                    Section("Ringkasan Kecepatan") {
                        LatencyCompareView(comparisons: comparisons)
                    }

                    Section("Detail Setiap Skenario") {
                        ForEach(comparisons) { c in
                            if let dataset {
                                TaskComparisonRow(comparison: c, dataset: dataset)
                            }
                        }
                    }
                }

                if !console.isEmpty {
                    Section {
                        DisclosureGroup("Log Teknis (untuk developer)") {
                            ScrollView {
                                Text(console.joined(separator: "\n"))
                                    .font(.caption2.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
            }
            .navigationTitle("Emotion POC")
            .translationTask(source: translationSourceLang, target: translationTargetLang) { session in
                guard translationSourceLang != nil else { return }
                do {
                    let response = try await session.translate("Halo, ini tes terjemahan.")
                    log("[translate SwiftUI id→en] ok: \"\(response.targetText)\"")
                } catch {
                    log("[translate SwiftUI id→en] FAILED: \(error)")
                }
            }
            .task {
                do {
                    let data = try DummyData.load()
                    dataset = data
                    log("[data] loaded \(data.emotionLogs.count) emotion logs, family \(data.family.name)")
                    availability = BenchmarkService.availabilitySummary()
                    log(availability)

                    // §2a known blocker: on-device generation doesn't support
                    // Indonesian (PERFORMANCE_COMPARISON.md §8a). Testing the
                    // Translation-framework workaround here too — real
                    // devices may have the id↔en language pack already
                    // downloaded (tied to the user's own language settings)
                    // even though the dev Mac host didn't.
                    do {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let translated = try await OnDeviceTranslator.translate(
                            "Halo, ini tes terjemahan.", from: OnDeviceTranslator.indonesian, to: OnDeviceTranslator.english
                        )
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                        log("[translate id→en] ok (\(String(format: "%.0f", ms))ms): \"\(translated)\"")
                    } catch {
                        log("[translate id→en] FAILED: \(error)")
                    }

                    if autoRun && !hasAutoRun {
                        hasAutoRun = true
                        await runComparison()
                    }
                } catch {
                    availability = "Failed to load dataset: \(error)"
                    log(availability)
                }
            }
        }
    }

    /// Runs both paths — server-side (OpenRouter) and on-device+translated
    /// (OnDeviceTranslationPipeline) — for every BenchmarkTask, and keeps
    /// them paired by task so the UI can show "same input, two outputs"
    /// instead of two separate lists you have to cross-reference by hand.
    /// Needs OPENROUTER_API_KEY in the process environment (see
    /// ServerOpenRouter.defaultConfig) and the id↔en language pack already
    /// installed (via the Setup button above) for the on-device path.
    private func runComparison() async {
        guard let dataset, !running else { return }
        runningComparison = true
        log("[comparison] starting")

        comparisons = BenchmarkTask.allCases.map { TaskComparison(task: $0) }
        await runServerPass(dataset: dataset)

        let session = LanguageModelSession(model: SystemLanguageModel.default)
        for (i, task) in BenchmarkTask.allCases.enumerated() {
            let r = await OnDeviceTranslationPipeline.run(task: task, data: dataset, session: session)
            comparisons[i].translated = r
            if r.ok {
                log("[onDevice+translate] \(task.rawValue) → total=\(String(format: "%.0f", r.totalMs))ms")
            } else {
                log("[onDevice+translate] \(task.rawValue) → FAILED (\(r.error ?? "?"))")
            }
        }

        log("[comparison] done")
        runningComparison = false
    }

    /// Server-only path — skips the on-device+translate loop entirely, so
    /// it doesn't need the id↔en language pack and is much faster to
    /// re-run while iterating on server-side prompt wording (added
    /// 2026-08-20 after many rounds of "just check the server output").
    private func runServerOnly() async {
        guard let dataset, !running else { return }
        runningServerOnly = true
        log("[server-only] starting")

        if comparisons.isEmpty {
            comparisons = BenchmarkTask.allCases.map { TaskComparison(task: $0) }
        }
        await runServerPass(dataset: dataset)

        log("[server-only] done")
        runningServerOnly = false
    }

    /// Shared by runComparison() and runServerOnly() — assumes `comparisons`
    /// already has one entry per BenchmarkTask.
    /// Fallback chain, per task: OpenRouter → Requesty → Gemini. Added
    /// 2026-08-21 after OpenRouter's free-tier daily cap (50 req/day) got
    /// exhausted mid-session from repeated testing. Requesty is
    /// OpenAI-compatible (same request/response shape as OpenRouter, so
    /// ServerOpenRouter.generate works against it directly with a
    /// different Config) — "mistral/leanstral-1-5" is its only free model
    /// with clean JSON-schema support (checked live against
    /// router.requesty.ai/v1/models). Gemini is a different API shape
    /// (Google's own, not OpenAI-compatible), handled by the existing
    /// ServerGemini.swift and re-tagged into a ServerOpenRouter.Result so
    /// the UI can render whichever provider actually answered without a
    /// separate result type.
    private func runServerPass(dataset: DummyDataset) async {
        let openRouterConfig = try? ServerOpenRouter.defaultConfig(apiKeyOverride: storedAPIKey)
        let requestyKey = [ProcessInfo.processInfo.environment["REQUESTY_API_KEY"], storedRequestyKey]
            .compactMap { $0 }.first(where: { !$0.isEmpty })
        let requestyConfig = requestyKey.map {
            ServerOpenRouter.Config(apiKey: $0, model: "mistral/leanstral-1-5", baseURL: "https://router.requesty.ai/v1")
        }
        let geminiConfig = try? ServerGemini.defaultConfig(apiKeyOverride: storedGeminiKey)

        for (i, task) in BenchmarkTask.allCases.enumerated() {
            let prompt = PromptBuilder.prompt(for: task, data: dataset)

            if let config = openRouterConfig {
                log("[openrouter:\(config.model)] \(task.rawValue) (\(i + 1)/\(BenchmarkTask.allCases.count)) → menunggu jawaban…")
                do {
                    let r = try await ServerOpenRouter.generate(task: task, prompt: prompt, config: config)
                    comparisons[i].server = r
                    log(ServerOpenRouter.format(r))
                    continue
                } catch {
                    log("[openrouter:\(config.model)] \(task.rawValue) → FAILED (\(error)), trying Requesty")
                }
            } else {
                log("[openrouter] no API key available, trying Requesty")
            }

            if let config = requestyConfig {
                log("[requesty:\(config.model)] \(task.rawValue) (\(i + 1)/\(BenchmarkTask.allCases.count)) → menunggu jawaban…")
                do {
                    var r = try await ServerOpenRouter.generate(task: task, prompt: prompt, config: config)
                    r.model = "requesty:\(config.model)"
                    comparisons[i].server = r
                    log(ServerOpenRouter.format(r))
                    continue
                } catch {
                    log("[requesty:\(config.model)] \(task.rawValue) → FAILED (\(error)), trying Gemini")
                }
            } else {
                log("[requesty] no API key available, trying Gemini")
            }

            if let config = geminiConfig {
                log("[gemini:\(config.model)] \(task.rawValue) (\(i + 1)/\(BenchmarkTask.allCases.count)) → menunggu jawaban…")
                do {
                    let r = try await ServerGemini.generate(task: task, prompt: prompt, config: config)
                    comparisons[i].server = ServerOpenRouter.Result(
                        model: "gemini:\(config.model)", task: task, ok: true, error: nil,
                        totalMs: r.totalMs, promptTokens: r.promptTokens, outputTokens: r.outputTokens,
                        reasoningTokens: 0, finishReason: "stop", outChars: r.outChars, outWords: r.outWords,
                        tokPerSec: r.tokPerSec, output: r.output
                    )
                    log(ServerGemini.format(r))
                    continue
                } catch {
                    log("[gemini:\(config.model)] \(task.rawValue) → FAILED (\(error))")
                }
            } else {
                log("[gemini] no API key available")
            }

            log("[server] \(task.rawValue) → all providers failed")
        }
    }

    private func log(_ line: String) {
        print(line)
        console.append(line)
        currentStatus = line
    }
}

#if DEBUG
extension ContentView {
    /// Every field OVERVIEW_JSON_SCHEMA can return, filled with realistic
    /// non-null content — including communication_style's before/after
    /// pair and both data_confidence tiers — so the "🧪 Muat Contoh
    /// Overview" debug button can prove the render path handles the whole
    /// shape, not just whichever fields a given live LLM response happened
    /// to fill in.
    static let debugSampleOverviewComparison: TaskComparison = {
        let json = """
        {
          "overview": {
            "headline": "Pola komunikasi mulai membaik minggu ini",
            "summary": "Ada indikasi Maya lebih terbuka soal sekolah, meski masih ada ketegangan seputar tugas rumah.",
            "patterns": [
              {
                "topic": "Pendidikan",
                "observation": "Percakapan soal tugas sekolah di hari Kamis cenderung diikuti mood yang menurun.",
                "suggested_approach": "Coba akui dulu rasa capeknya sebelum masuk ke soal jadwal tugas."
              },
              {
                "topic": "Keluarga",
                "observation": "Beberapa catatan menyebut Maya merasa buru-buru diminta beres-beres.",
                "suggested_approach": "Tanyakan waktu yang nyaman buat beres-beres, bukan langsung minta sekarang."
              }
            ],
            "relationship_signal": {
              "parent_concern": "moderate",
              "child_openness": "moderate",
              "possible_misalignment": true
            },
            "communication_style": {
              "detected_pattern": "bald_on_record",
              "example_before": "Kamu harus beresin kamar sekarang juga.",
              "example_after": "Mungkin lebih enak kalau kamarnya dirapiin sebelum makan malam, gimana?"
            },
            "data_confidence": {
              "child": "building",
              "parent": "high"
            },
            "key_insight": "Maya mungkin butuh waktu jeda sebelum diajak bicara soal tugas, meski ini belum dikonfirmasi langsung dari sisi Maya."
          }
        }
        """
        var comparison = TaskComparison(task: .overview)
        comparison.server = ServerOpenRouter.Result(
            model: "debug-sample", task: .overview, ok: true, error: nil,
            totalMs: 0, promptTokens: 0, outputTokens: 0, reasoningTokens: 0,
            finishReason: "debug", outChars: json.count, outWords: 0, tokPerSec: 0,
            output: json
        )
        return comparison
    }()
}
#endif

struct TaskComparisonRow: View {
    let comparison: TaskComparison
    let dataset: DummyDataset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HumanLabels.taskName(comparison.task))
                .font(.headline)
            Text(HumanLabels.taskDescription(comparison.task))
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Apa yang diuji?") {
                TaskInputView(task: comparison.task, data: dataset)
            }

            if let server = comparison.server {
                resultBlock(
                    title: "☁️ Jawaban dari Server",
                    ok: server.ok,
                    error: server.error,
                    totalMs: server.totalMs,
                    technical: [
                        ("Total", String(format: "%.0f ms", server.totalMs)),
                        ("Tokens", "masuk=\(server.promptTokens) keluar=\(server.outputTokens) reasoning=\(server.reasoningTokens)"),
                        ("Throughput", String(format: "%.1f tok/s", server.tokPerSec)),
                        ("Model", server.model),
                    ],
                    output: TaskOutputView(task: comparison.task, raw: server.output)
                )
            }

            if let translated = comparison.translated {
                resultBlock(
                    title: "📱 Jawaban dari HP (On-Device)",
                    ok: translated.ok,
                    error: translated.error,
                    totalMs: translated.totalMs,
                    technical: [
                        ("Total", String(format: "%.0f ms", translated.totalMs)),
                        ("Proses jawab", String(format: "%.0f ms", translated.generateMs)),
                        ("Terjemahkan", String(format: "%.0f ms", translated.translateMs)),
                    ],
                    output: TaskOutputView(task: comparison.task, raw: translated.output)
                )
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func resultBlock<Output: View>(
        title: String, ok: Bool, error: String?, totalMs: Double,
        technical: [(String, String)], output: Output
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                if ok {
                    Text(String(format: "⏱ %.1f detik", totalMs / 1000))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if ok {
                output

                DisclosureGroup("Info teknis") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        ForEach(technical, id: \.0) { metric in
                            GridRow {
                                Text(metric.0)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(metric.1)
                                    .font(.caption2.monospaced())
                            }
                        }
                    }
                }
            } else {
                Text("Gagal: \(error ?? "unknown error")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
