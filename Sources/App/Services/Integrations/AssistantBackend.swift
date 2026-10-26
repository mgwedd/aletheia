import Foundation

/// Which local LLM backend powers summaries and chat.
///
/// The design goal (see README) is that a therapist on a modern Mac gets
/// working AI with *nothing to install*: Apple Intelligence runs the model
/// on-device, managed by the OS. Where that isn't available the app falls
/// back to the built-in llama.cpp engine. This enum is the
/// user-facing preference; `AssistantBackendResolver` turns it into the
/// backend that will actually run given what this Mac supports.
enum AssistantBackend: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Pick the best available backend automatically (the recommended default).
    case automatic
    /// Apple's on-device Foundation Models (Apple Intelligence). No install,
    /// no model download, no external process.
    case appleIntelligence
    /// Embedded llama.cpp runtime bundled in the app.
    case localLlama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .localLlama: return "Built-in model"
        }
    }

    /// One-line explanation shown under the picker.
    var summary: String {
        switch self {
        case .automatic:
            return "Use the AI model built into Aletheia."
        case .appleIntelligence:
            return "Runs entirely on your Mac with nothing to install. Requires a Mac that supports Apple Intelligence."
        case .localLlama:
            return "A model built into Aletheia itself. Nothing else to install."
        }
    }
}

extension AssistantBackend {
    /// The engine choices the Settings picker should offer, given what this
    /// build actually ships and what this Mac supports. Pure and framework-free
    /// so the gating is unit-testable without a view or `FeatureRegistry`
    /// instance — the view just forwards its two facts in.
    ///
    /// `.localLlama` ("Built-in model") is withheld unless the embedded
    /// llama.cpp module is present in this build's `FeatureRegistry` (see
    /// `EmbeddedLlamaFeatureModule`), so a build without it never advertises
    /// an engine that is not there. `.appleIntelligence` is withheld while
    /// `Integrations.appleIntelligenceBlocked` holds it off (kept provably
    /// on-device — see project README). Neither flag changes
    /// `AssistantBackendResolver`'s fallback behavior for an already-selected
    /// preference.
    static func selectableOptions(embeddedLlamaAvailable: Bool, appleIntelligenceBlocked: Bool) -> [AssistantBackend] {
        allCases.filter { backend in
            if backend == .appleIntelligence && appleIntelligenceBlocked { return false }
            if backend == .localLlama && !embeddedLlamaAvailable { return false }
            return true
        }
    }

    /// Whether the Engine menu is worth showing: only when there are two real
    /// engines to choose between. With just the built-in model, "Automatic" and
    /// "Built-in model" mean the same thing, so the menu is hidden.
    static func offersEngineChoice(_ options: [AssistantBackend]) -> Bool {
        options.filter { $0 != .automatic }.count > 1
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

    /// Everything that isn't an available Apple Intelligence resolves to the
    /// built-in engine, the only other engine there is. (In a build without the
    /// llama.cpp runtime that engine reports itself unavailable; see
    /// `UnavailableAssistant`.)
    func resolve(_ preference: AssistantBackend) -> AssistantBackend {
        switch preference {
        case .automatic, .appleIntelligence:
            return appleIntelligenceAvailable ? .appleIntelligence : .localLlama
        case .localLlama:
            return .localLlama
        }
    }

    /// Decodes a stored preference. Anything unrecognised, including the
    /// value from an older version, means the built-in engine.
    static func preference(fromStored raw: String?) -> AssistantBackend {
        raw.flatMap(AssistantBackend.init(rawValue:)) ?? .automatic
    }
}
