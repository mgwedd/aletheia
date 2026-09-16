#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// On-device LLM via Apple's Foundation Models framework (Apple Intelligence).
///
/// There's no server, no model file to download, and no external process: the
/// model ships with the OS and Apple updates it. On a Mac that supports Apple
/// Intelligence this is the primary backend — it's what lets setup be truly
/// zero-install for the everyday user. The app falls back to Ollama where it
/// isn't available.
///
/// The whole file is behind `#if canImport(FoundationModels)` so it compiles
/// out cleanly on toolchains whose SDK predates the framework (the CI image
/// today builds with Xcode 16, which has no FoundationModels), and lights up
/// automatically when Session Notes is built with a newer Xcode. Nothing else
/// in the app references this type without the same guard.
@available(macOS 26.0, *)
final class FoundationModelsAssistant: Assistant {
    /// Whether the on-device model is present and usable right now.
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        case .unavailable: return false
        @unknown default: return false
        }
    }

    /// Plain-language reason the model can't be used, or nil when it's ready.
    /// Used by the status/setup screens so the user knows what (if anything) to
    /// do about it.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model. Try again in a few minutes."
            @unknown default:
                return "Apple Intelligence isn't available right now."
            }
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }

    func isReachable() async -> Bool { Self.isAvailable }

    // The system model is singular and OS-managed: from the app's side there's
    // nothing to enumerate, verify, or download.
    func listModels() async throws -> [String] { ["Apple Intelligence"] }
    func hasModel(_ name: String) async -> Bool { Self.isAvailable }

    func generate(model: String, prompt: String) async throws -> String {
        // A fresh session per request keeps summaries/chat turns independent;
        // the app already carries its own conversation context in the prompt.
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        // Nothing to download — the OS manages the model lifecycle.
        onProgress(1.0, "ready")
    }
}
#endif
