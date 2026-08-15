import Foundation
import FoundationModels

enum ModelKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case onDevice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: return "On-device (SystemLanguageModel)"
        }
    }
}

struct BenchmarkResult: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: ModelKind
    var task: BenchmarkTask
    var phase: String
    var ok: Bool
    var error: String?
    var loadMs: Double?
    var ttftMs: Double
    var totalMs: Double
    var outChars: Int
    var outWords: Int
    var estTokens: Int
    var tokPerSec: Double
    var charsPerSec: Double
    var output: String

    static func failed(kind: ModelKind, task: BenchmarkTask, phase: String, error: String) -> BenchmarkResult {
        BenchmarkResult(
            id: UUID(), kind: kind, task: task, phase: phase,
            ok: false, error: error,
            loadMs: nil, ttftMs: 0, totalMs: 0,
            outChars: 0, outWords: 0, estTokens: 0,
            tokPerSec: 0, charsPerSec: 0, output: ""
        )
    }
}

enum BenchmarkService {

    // MARK: - Availability

    static func isAvailable(_ kind: ModelKind) -> Bool {
        switch kind {
        case .onDevice:
            return SystemLanguageModel.default.isAvailable
        }
    }

    static func availabilitySummary() -> String {
        let a = SystemLanguageModel.default.availability
        var summary = "SystemLanguageModel.default.availability = \(a)"
        if case .unavailable(let reason) = a {
            summary += "\nreason = \(reason)"
        }
        return summary
    }

    // MARK: - Formatting

    static func format(_ r: BenchmarkResult) -> String {
        var line = "[\(r.kind.rawValue)] \(r.task.rawValue) · \(r.phase) → "
        guard r.ok else {
            return line + "FAILED (\(r.error ?? "unknown"))"
        }
        var parts: [String] = []
        if let load = r.loadMs {
            parts.append("load=\(String(format: "%.0f", load))ms")
        }
        parts.append("ttft=\(String(format: "%.0f", r.ttftMs))ms")
        parts.append("total=\(String(format: "%.0f", r.totalMs))ms")
        parts.append("out=\(r.estTokens)tok/\(r.outChars)chars/\(r.outWords)w")
        parts.append("\(String(format: "%.1f", r.tokPerSec))tok/s")
        return line + parts.joined(separator: " ")
    }

    // MARK: - Session construction

    private static func makeSession(_ kind: ModelKind) -> LanguageModelSession {
        switch kind {
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default)
        }
    }

    // MARK: - Single generation

    private static func generate(
        session: LanguageModelSession,
        prompt: String
    ) async throws -> (output: String, ttftMs: Double, totalMs: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        var ttftMs: Double = 0
        var totalMs: Double = 0
        var output = ""
        var started = false

        let stream = session.streamResponse(to: Prompt(prompt), options: GenerationOptions())
        for try await snapshot in stream {
            if !started {
                started = true
                ttftMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            output = snapshot.content
        }
        totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return (output, ttftMs, totalMs)
    }

    // MARK: - Single run (one task on one model, one phase)

    static func runOnce(
        kind: ModelKind,
        task: BenchmarkTask,
        data: DummyDataset,
        phase: String,
        session: LanguageModelSession?
    ) async -> BenchmarkResult {
        do {
            let prompt = PromptBuilder.prompt(for: task, data: data)
            let s: LanguageModelSession
            var loadMs: Double? = nil

            if let existing = session {
                s = existing
            } else {
                s = makeSession(kind)
                if phase == "cold" {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    try await s.prewarm(promptPrefix: Prompt("Summarize this diary"))
                    loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                }
            }

            let (output, ttft, total) = try await generate(session: s, prompt: prompt)

            let outChars = output.count
            let outWords = output.split(whereSeparator: \.isWhitespace).count
            let estTokens = outChars / 4
            let totalSec = total / 1000

            return BenchmarkResult(
                id: UUID(),
                kind: kind,
                task: task,
                phase: phase,
                ok: true,
                error: nil,
                loadMs: loadMs,
                ttftMs: ttft,
                totalMs: total,
                outChars: outChars,
                outWords: outWords,
                estTokens: estTokens,
                tokPerSec: totalSec > 0 ? Double(estTokens) / totalSec : 0,
                charsPerSec: totalSec > 0 ? Double(outChars) / totalSec : 0,
                output: output
            )
        } catch {
            return .failed(kind: kind, task: task, phase: phase, error: "\(error)")
        }
    }

    // MARK: - Full benchmark (cold + warm, all tasks, all models)

    static func runFull(data: DummyDataset) async -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        for kind in ModelKind.allCases {
            let available = isAvailable(kind)

            guard available else {
                results.append(.failed(
                    kind: kind, task: BenchmarkTask.overview, phase: "cold",
                    error: "Model not available on this device/simulator. Run availability check."
                ))
                continue
            }

            for task in BenchmarkTask.allCases {
                // Cold: fresh session + prewarm (first load pays ANE compilation / model download)
                let session = makeSession(kind)
                let cold = await runOnce(kind: kind, task: task, data: data, phase: "cold", session: session)
                results.append(cold)

                // Warm: reuse the same session (model already resident)
                let warm = await runOnce(kind: kind, task: task, data: data, phase: "warm", session: session)
                results.append(warm)
            }
        }
        return results
    }
}
