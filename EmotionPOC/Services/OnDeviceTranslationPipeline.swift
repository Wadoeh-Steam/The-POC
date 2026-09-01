import Foundation
import FoundationModels

/// The actual workaround for §2a's on-device blocker: Apple Intelligence
/// doesn't support Indonesian generation, so this runs the *English*
/// prompts (EnglishPromptBuilder.swift) through FoundationModels, then
/// translates the JSON output back to Indonesian with OnDeviceTranslator —
/// every String leaf gets translated except a small set of known enum/
/// classifier literals (e.g. `relationship_signal.parent_concern:
/// low|moderate|high`), which are for the app's own logic, not prose a
/// parent reads. User-facing output must always be Bahasa Indonesia, same
/// as the server (OpenRouter) path, which prompts in Indonesian directly.
///
/// Confirmed viable 2026-08-16 (PERFORMANCE_COMPARISON.md §8f) once the
/// id↔en language pack is installed on-device — this pipeline is what
/// turns that proof-of-concept into something that actually produces a
/// usable Indonesian result end-to-end.
enum OnDeviceTranslationPipeline {

    struct Result: Identifiable {
        let id = UUID()
        var task: BenchmarkTask
        var ok: Bool
        var error: String?
        var generateMs: Double
        var translateMs: Double
        var totalMs: Double
        var output: String
    }

    static func run(task: BenchmarkTask, data: DummyDataset, session: LanguageModelSession) async -> Result {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let prompt = EnglishPromptBuilder.prompt(for: task, data: data)

            let genStart = DispatchTime.now().uptimeNanoseconds
            let stream = session.streamResponse(to: Prompt(prompt), options: GenerationOptions())
            var englishOutput = ""
            for try await snapshot in stream {
                englishOutput = snapshot.content
            }
            let generateMs = Double(DispatchTime.now().uptimeNanoseconds - genStart) / 1_000_000

            let translateStart = DispatchTime.now().uptimeNanoseconds
            let indonesianOutput = try await translateOutput(task: task, englishOutput: englishOutput)
            let translateMs = Double(DispatchTime.now().uptimeNanoseconds - translateStart) / 1_000_000

            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            return Result(
                task: task, ok: true, error: nil,
                generateMs: generateMs, translateMs: translateMs, totalMs: totalMs,
                output: indonesianOutput
            )
        } catch {
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            return Result(task: task, ok: false, error: "\(error)", generateMs: 0, translateMs: 0, totalMs: totalMs, output: "")
        }
    }

    // MARK: - Output translation

    /// Object keys whose value must survive untouched — these are for the
    /// app's own logic (rendered via the app's own localized labels), not
    /// prose a parent reads. Checked by KEY, not by matching the value
    /// against a known literal: FoundationModels is called with plain
    /// `GenerationOptions()` (no `@Generable`/JSON-schema constraint, unlike
    /// the OpenRouter path's `response_format`/`json_schema` in
    /// _shared/llm.ts), so its casing/spelling for an enum value isn't
    /// guaranteed — a value-based skip-list (e.g. matching "bald_on_record"
    /// exactly) would translate a drifted "Bald_on_record" and corrupt a
    /// value the client switches on. A key-based skip is correct regardless
    /// of what the model actually outputs there.
    private static let nonTranslatableKeys: Set<String> = [
        "parent_concern", "child_openness", "possible_misalignment",
        "detected_pattern", "data_confidence",
        "frustration_level", "reflection_depth",
    ]

    /// Recursively translates every String leaf in a decoded JSON value
    /// (dict/array of Any) from English to Indonesian, skipping only values
    /// under a nonTranslatableKeys key. Deliberately recurse-and-translate-
    /// by-default rather than hand-listing which keys ARE prose: a hand-
    /// listed allowlist silently leaves new free-text fields in English when
    /// the schema grows and the list isn't updated — exactly what happened
    /// here when suggested_approach/example_before/example_after were added
    /// to the overview schema (2026-08-25) without updating the old
    /// per-field translation code. Recurse-by-default fails safe: a new
    /// field defaults to being translated, not silently skipped.
    private static func translateJSONStrings(_ value: Any) async throws -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return value
            }
            return try await OnDeviceTranslator.translate(
                string, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian
            )
        }
        if let dict = value as? [String: Any] {
            var translated: [String: Any] = [:]
            for (key, v) in dict {
                translated[key] = nonTranslatableKeys.contains(key) ? v : try await translateJSONStrings(v)
            }
            return translated
        }
        if let array = value as? [Any] {
            var translated: [Any] = []
            for v in array {
                translated.append(try await translateJSONStrings(v))
            }
            return translated
        }
        return value // numbers, bools, NSNull — pass through unchanged.
    }

    private static func translateOutput(task: BenchmarkTask, englishOutput: String) async throws -> String {
        switch task {
        case .howToReact:
            // Plain text, no structure to preserve — translate the whole thing.
            return try await OnDeviceTranslator.translate(
                englishOutput, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian
            )

        case .extraction:
            let json = try decodeJSONObject(stripFences(englishOutput))
            guard let translated = try await translateJSONStrings(json) as? [String: Any] else { return englishOutput }
            return try encodeJSON(translated)

        case .overview:
            let json = try decodeJSONObject(stripFences(englishOutput))
            guard let translated = try await translateJSONStrings(json) as? [String: Any] else { return englishOutput }
            return try encodeJSON(translated)

        case .reflection:
            // FoundationModels sometimes returns a bare JSON array (just
            // the recommendations list) instead of the requested
            // {"recommendations": [...]} shape — observed live on-device,
            // 2026-08-16. Accept both rather than failing on the model's
            // weaker instruction-following for this specific shape.
            let cleaned = stripFences(englishOutput)
            var json: [String: Any]
            if let bareArray = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [[String: Any]] {
                json = ["recommendations": bareArray]
            } else {
                json = try decodeJSONObject(cleaned)
            }
            guard let translated = try await translateJSONStrings(json) as? [String: Any] else { return englishOutput }
            return try encodeJSON(translated)
        }
    }

    // MARK: - JSON helpers

    private static func stripFences(_ text: String) -> String {
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

    private static func decodeJSONObject(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OnDeviceTranslationPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to decode JSON: \(text)"])
        }
        return obj
    }

    private static func encodeJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
