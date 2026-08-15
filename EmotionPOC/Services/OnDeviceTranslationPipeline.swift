import Foundation
import FoundationModels

/// The actual workaround for §2a's on-device blocker: Apple Intelligence
/// doesn't support Indonesian generation, so this runs the *English*
/// prompts (EnglishPromptBuilder.swift) through FoundationModels, then
/// translates only the free-text output fields back to Indonesian with
/// OnDeviceTranslator — leaving structural/enum fields (e.g.
/// `relationship_signal.parent_concern: low|moderate|high`) untouched,
/// since those are meant for the app's own logic, not for a parent to
/// read as prose.
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

    // MARK: - Selective output translation

    private static func translateOutput(task: BenchmarkTask, englishOutput: String) async throws -> String {
        switch task {
        case .howToReact:
            // Plain text, no structure to preserve — translate the whole thing.
            return try await OnDeviceTranslator.translate(
                englishOutput, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian
            )

        case .extraction:
            var json = try decodeJSONObject(stripFences(englishOutput))
            if var extracted = json["extracted"] as? [String: Any?] {
                for key in extracted.keys {
                    if let value = extracted[key] as? String {
                        extracted[key] = try await OnDeviceTranslator.translate(
                            value, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian
                        )
                    }
                }
                json["extracted"] = extracted
            }
            // crisis_signal is a boolean — deliberately untouched.
            return try encodeJSON(json)

        case .overview:
            var json = try decodeJSONObject(stripFences(englishOutput))
            guard var overview = json["overview"] as? [String: Any] else { return englishOutput }

            if let headline = overview["headline"] as? String {
                overview["headline"] = try await OnDeviceTranslator.translate(headline, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
            }
            if let summary = overview["summary"] as? String {
                overview["summary"] = try await OnDeviceTranslator.translate(summary, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
            }
            if let keyInsight = overview["key_insight"] as? String {
                overview["key_insight"] = try await OnDeviceTranslator.translate(keyInsight, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
            }
            if let patterns = overview["patterns"] as? [[String: Any]] {
                var translatedPatterns: [[String: Any]] = []
                for var pattern in patterns {
                    if let topic = pattern["topic"] as? String {
                        pattern["topic"] = try await OnDeviceTranslator.translate(topic, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
                    }
                    if let observation = pattern["observation"] as? String {
                        pattern["observation"] = try await OnDeviceTranslator.translate(observation, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
                    }
                    translatedPatterns.append(pattern)
                }
                overview["patterns"] = translatedPatterns
            }
            // relationship_signal (parent_concern/child_openness/possible_misalignment)
            // deliberately left untouched — app-level enum, not display prose.
            json["overview"] = overview
            return try encodeJSON(json)

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
            if let recommendations = json["recommendations"] as? [[String: Any]] {
                var translated: [[String: Any]] = []
                for var rec in recommendations {
                    for key in ["title", "description", "based_on"] {
                        if let value = rec[key] as? String {
                            rec[key] = try await OnDeviceTranslator.translate(value, from: OnDeviceTranslator.english, to: OnDeviceTranslator.indonesian)
                        }
                    }
                    translated.append(rec)
                }
                json["recommendations"] = translated
            }
            return try encodeJSON(json)
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
