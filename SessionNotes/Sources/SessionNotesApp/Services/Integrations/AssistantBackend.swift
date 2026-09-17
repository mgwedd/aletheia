import Foundation

/// Which local LLM backend powers summaries and chat.
///
/// The design goal (see README) is that a therapist on a modern Mac gets
/// working AI with *nothing to install*: Apple Intelligence runs the model
/// on-device, managed by the OS. Where that isn't available the app falls
/// back to a backend that can be installed or bundled. This enum is the
/// user-facing preference; `AssistantBackendResolver` turns it into the
/// backend that will actually run given what this Mac supports.
enum AssistantBackend: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Pick the best available backend automatically (the recommended default).
    case automatic
    /// Apple's on-device Foundation Models (Apple Intelligence). No install,
    /// no model download, no external process.
    case appleIntelligence
    /// A local Ollama server reached over its HTTP API.
    case ollama
    /// Embedded llama.cpp runtime bundled in the app (staged — see
    /// `Integrations.makeAssistant()` and the README for the rollout plan).
    case localLlama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .ollama: return "Ollama"
        case .localLlama: return "Built-in model"
        }
    }

    /// One-line explanation shown under the picker.
    var summary: String {
        switch self {
        case .automatic:
            return "Use Apple Intelligence when this Mac supports it, otherwise fall back automatically."
        case .appleIntelligence:
            return "Runs entirely on your Mac with nothing to install. Requires a Mac that supports Apple Intelligence."
        case .ollama:
            return "Runs a model through the free Ollama app. Works on older Macs; needs a one-time install."
        case .localLlama:
            return "A model built into Session Notes itself."
        }
    }
}

/// Pure decision logic: given what's actually available on this Mac, decides
/// which concrete backend a preference resolves to. Deliberately free of any
/// framework or `AppSettings` dependency so it's unit-tested in isolation and
/// the availability facts are injected by the caller.
struct AssistantBackendResolver {
    /// Whether Apple's Foundation Models are usable right now (supported Mac,
    /// Apple Intelligence enabled, model downloaded).
    var appleIntelligenceAvailable: Bool
    /// Whether the embedded llama.cpp runtime is bundled and ready.
    var localLlamaAvailable: Bool

    func resolve(_ preference: AssistantBackend) -> AssistantBackend {
        switch preference {
        case .automatic:
            if appleIntelligenceAvailable { return .appleIntelligence }
            if localLlamaAvailable { return .localLlama }
            return .ollama
        case .appleIntelligence:
            return appleIntelligenceAvailable ? .appleIntelligence : fallback
        case .localLlama:
            return localLlamaAvailable ? .localLlama : fallback
        case .ollama:
            return .ollama
        }
    }

    /// When an explicitly chosen on-device backend isn't available, prefer the
    /// embedded runtime if present, otherwise Ollama (which the user can always
    /// install) — never fail outright.
    private var fallback: AssistantBackend {
        localLlamaAvailable ? .localLlama : .ollama
    }
}
