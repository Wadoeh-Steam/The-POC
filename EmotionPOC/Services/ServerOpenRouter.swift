import Foundation

/// Benchmark client for the *actual* production LLM path — OpenRouter
/// (ADR-0010), not a direct Gemini call. Non-streaming, matching
/// `supabase/functions/_shared/llm.ts` exactly (production Edge Functions
/// don't stream to the client either), unlike `ServerGemini.swift`'s SSE
/// approach from the Phase 0 POC. That file is kept as-is, unmodified —
/// still valid as the historical Phase 0 record (ARCHITECTURE.md §1) —
/// this one supersedes it as the thing actually worth benchmarking now.
enum ServerOpenRouter {

    struct Config {
        var apiKey: String
        var model: String
        var baseURL: String
    }

    /// Default model matches the production default as of ADR-0010's
    /// final decision (free tier, empirically chosen after 4 of 5
    /// candidates failed testing) — override via OPENROUTER_MODEL to
    /// compare against something else.
    static func defaultConfig() throws -> Config {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            throw NSError(domain: "ServerOpenRouter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "OPENROUTER_API_KEY env var missing"])
        }
        let model = ProcessInfo.processInfo.environment["OPENROUTER_MODEL"] ?? "nvidia/nemotron-nano-9b-v2:free"
        let base = ProcessInfo.processInfo.environment["OPENROUTER_BASE_URL"] ?? "https://openrouter.ai/api/v1"
        return Config(apiKey: key, model: model, baseURL: base)
    }

    struct Result {
        var model: String
        var task: BenchmarkTask
        var ok: Bool
        var error: String?
        var totalMs: Double
        var promptTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var finishReason: String
        var outChars: Int
        var outWords: Int
        var tokPerSec: Double
        var output: String
    }

    /// Single non-streaming generation. `maxOutputTokens` defaults high —
    /// see ARCHITECTURE.md/ADR-0010: the free default model spends a real,
    /// unpredictable chunk of its budget on reasoning tokens before the
    /// actual answer, and truncates (finish_reason: "length") without
    /// enough headroom.
    static func generate(
        task: BenchmarkTask,
        prompt: String,
        config: Config,
        maxOutputTokens: Int = 6000
    ) async throws -> Result {
        let url = URL(string: "\(config.baseURL)/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        // `/no_think` — Nemotron-specific system-prompt convention (not a
        // generic OpenRouter API param) to disable its chain-of-thought
        // reasoning. Found 2026-08-15 after the generic `reasoning:
        // {enabled: false}` API parameter barely helped (36.5s → 14.3s,
        // still 587 reasoning tokens) — this cut it to ~2.6s with 0
        // reasoning tokens and, in testing, *better* extraction quality
        // (quotes actual content instead of vague present/absent markers).
        // Model-specific — would need reconsidering if the default model
        // changes (see ADR-0010).
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "/no_think"],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.2,
            "max_tokens": maxOutputTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await URLSession.shared.data(for: request)
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ServerOpenRouter", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyText)"])
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ServerOpenRouter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Malformed response"])
        }

        let choices = obj["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let output = (message?["content"] as? String) ?? ""
        let finishReason = (choices.first?["finish_reason"] as? String) ?? "unknown"

        let usage = obj["usage"] as? [String: Any] ?? [:]
        let promptTokens = usage["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage["completion_tokens"] as? Int ?? 0
        let completionDetails = usage["completion_tokens_details"] as? [String: Any] ?? [:]
        let reasoningTokens = completionDetails["reasoning_tokens"] as? Int ?? 0

        guard !output.isEmpty else {
            throw NSError(domain: "ServerOpenRouter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Empty response from \(config.model) (finish_reason: \(finishReason))"])
        }

        let outChars = output.count
        let outWords = output.split(whereSeparator: \.isWhitespace).count
        let totalSec = totalMs / 1000

        return Result(
            model: config.model,
            task: task,
            ok: true,
            error: nil,
            totalMs: totalMs,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            finishReason: finishReason,
            outChars: outChars,
            outWords: outWords,
            tokPerSec: totalSec > 0 ? Double(outputTokens) / totalSec : 0,
            output: output
        )
    }

    static func format(_ r: Result) -> String {
        guard r.ok else {
            return "[openrouter:\(r.model)] \(r.task.rawValue) → FAILED (\(r.error ?? "?"))"
        }
        var line = "[openrouter:\(r.model)] \(r.task.rawValue) → total=\(String(format: "%.0f", r.totalMs))ms " +
            "in=\(r.promptTokens)tok out=\(r.outputTokens)tok"
        if r.reasoningTokens > 0 {
            line += " (reasoning=\(r.reasoningTokens)tok)"
        }
        line += "/\(r.outChars)chars/\(r.outWords)w " +
            String(format: "%.1f", r.tokPerSec) + "tok/s finish=\(r.finishReason)"
        return line
    }

    /// Same cleanup as the Phase 0 POC's on-device path — free-tier output
    /// isn't guaranteed clean JSON any more than on-device was
    /// (PERFORMANCE_COMPARISON.md), and this benchmark doesn't enforce
    /// response_format/json_schema (kept deliberately simple, unlike the
    /// production Edge Functions) so fence-wrapping is a real possibility here.
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
}
