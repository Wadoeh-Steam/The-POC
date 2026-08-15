import Foundation
import Translation

/// Workaround for §2a's known blocker: Apple Intelligence's on-device
/// generation (FoundationModels) doesn't support Bahasa Indonesia yet
/// (PERFORMANCE_COMPARISON.md §8a), but Apple's separate `Translation`
/// framework does — it's a different, older, more mature on-device ML
/// feature with broader language coverage than the newer generative model.
///
/// Uses `TranslationSession.init(installedSource:target:)` — the one
/// non-SwiftUI-bound initializer (everything else on this API is tied to
/// a `.translationTask` view modifier). This throws if the language pair
/// isn't already downloaded on the device (Settings → General → Language
/// & Region → Translation Languages, or triggered once via the system
/// Translate app) — there's no way to prompt for download outside SwiftUI,
/// so a clear, actionable error is the best this can do in a CLI context.
enum OnDeviceTranslator {

    enum TranslatorError: Error, CustomStringConvertible {
        case languagePairNotInstalled(from: String, to: String, underlying: Error)

        var description: String {
            switch self {
            case .languagePairNotInstalled(let from, let to, let underlying):
                return "Translation \(from)→\(to) not available — language pack likely not downloaded on this device. " +
                    "Install via Settings → General → Language & Region → Translation Languages (or open Translate.app once). " +
                    "Underlying error: \(underlying)"
            }
        }
    }

    static func translate(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> String {
        do {
            let session = try TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw TranslatorError.languagePairNotInstalled(
                from: source.languageCode?.identifier ?? "?",
                to: target.languageCode?.identifier ?? "?",
                underlying: error
            )
        }
    }

    static let indonesian = Locale.Language(identifier: "id")
    static let english = Locale.Language(identifier: "en")
}
