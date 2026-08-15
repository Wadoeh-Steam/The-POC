import Foundation

/// Minimal Google Gemini streaming client for benchmarking.
/// Uses the generateContent API (SSE) — report URL: /v1beta/models/{model}:streamGenerateContent
enum ServerGemini {

    struct Config {
        var apiKey: String
        var model: String
        var baseURL: String
    }

    static func defaultConfig() throws -> Config {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            throw NSError(domain: "ServerGemini", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY env var missing"])
        }
        let model = ProcessInfo.processInfo.environment["GEMINI_MODEL"] ?? "gemini-flash-lite-latest"
        let base = ProcessInfo.processInfo.environment["GEMINI_BASE_URL"] ?? "https://generativelanguage.googleapis.com/v1beta"
        return Config(apiKey: key, model: model, baseURL: base)
    }

    struct Result {
        var model: String
        var task: BenchmarkTask
        var ok: Bool
        var error: String?
        var ttftMs: Double
        var totalMs: Double
        var promptTokens: Int
        var outputTokens: Int
        var outChars: Int
        var outWords: Int
        var tokPerSec: Double
        var output: String
    }

    /// Streams a single generation, measuring TTFT (time-to-first-token) and total time.
    static func generate(task: BenchmarkTask, prompt: String, config: Config) async throws -> Result {
        let url = URL(string: "\(config.baseURL)/models/\(config.model):streamGenerateContent?alt=sse&key=\(config.apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 1024,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var bytes: URLSession.AsyncBytes
        var response: URLResponse
        let maxAttempts = 3
        var attempt = 0
        var attemptStart = DispatchTime.now().uptimeNanoseconds
        while true {
            attempt += 1
            attemptStart = DispatchTime.now().uptimeNanoseconds
            (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 503, attempt < maxAttempts {
                print("[server:\(config.model)] \(task.rawValue) → 503, retry \(attempt)/\(maxAttempts - 1)...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            break
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ServerGemini", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        let start = attemptStart
        var output = ""
        var ttftMs: Double = 0
        var promptTokens = 0
        var outputTokens = 0
        var firstText = true

        var buffer = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }

            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }

            if let usage = obj["usageMetadata"] as? [String: Any] {
                promptTokens = usage["promptTokenCount"] as? Int ?? promptTokens
                outputTokens = usage["candidatesTokenCount"] as? Int ?? outputTokens
            }

            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let candidate = candidates.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }

            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty && firstText {
                ttftMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                firstText = false
            }
            output += text
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        guard !output.isEmpty else {
            throw NSError(domain: "ServerGemini", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Empty response from \(config.model)"])
        }

        let outChars = output.count
        let outWords = output.split(whereSeparator: \.isWhitespace).count
        _ = buffer
        return Result(
            model: config.model,
            task: task,
            ok: true,
            error: nil,
            ttftMs: ttftMs,
            totalMs: totalMs,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            outChars: outChars,
            outWords: outWords,
            tokPerSec: Double(outputTokens) / max(totalMs / 1000, 0.001),
            output: output
        )
    }

    static func format(_ r: Result) -> String {
        guard r.ok else {
            return "[server:\(r.model)] \(r.task.rawValue) → FAILED (\(r.error ?? "?"))"
        }
        return "[server:\(r.model)] \(r.task.rawValue) → ttft=\(String(format: "%.0f", r.ttftMs))ms " +
            "total=\(String(format: "%.0f", r.totalMs))ms " +
            "in=\(r.promptTokens)tok out=\(r.outputTokens)tok/\(r.outChars)chars/\(r.outWords)w " +
            String(format: "%.1f", r.tokPerSec) + "tok/s"
    }

    /// Strips markdown code fences (```json ... ```) so JSON can be parsed cleanly.
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