import Foundation

/// What went wrong with the built-in AI engine, in the terms a therapist can act
/// on, and the one next step to offer. Pure — no I/O — so the mapping from an
/// error to "which button do we show" is unit-tested without a Mac.
///
/// ```
/// LocalLLMEngineError.modelNotDownloaded ──────────▶ builtInModelMissing [Download model]
/// LocalLLMEngineError.loadFailed ──────────────────▶ builtInModelCorrupt [Re-download model]
/// LocalLLMEngineError.outOfMemory / generationFailed ▶ erroring          [Try again]
/// BuiltInModelUnavailableError ────────────────────▶ erroring            [Try again]
/// anything else ───────────────────────────────────▶ nil (normal error alert)
/// ```
enum AIEngineProblem: Equatable {
    case erroring(String)
    /// The built-in engine's model isn't downloaded yet.
    case builtInModelMissing
    /// The built-in engine's model file failed to load (corrupt or incomplete).
    case builtInModelCorrupt

    enum Action: Equatable {
        case downloadBuiltInModel
        case retry
    }

    static func from(error: Error) -> AIEngineProblem? {
        if let unavailable = error as? BuiltInModelUnavailableError {
            return .erroring(unavailable.localizedDescription)
        }
        guard let local = error as? LocalLLMEngineError else { return nil }
        switch local {
        case .modelNotDownloaded: return .builtInModelMissing
        case .loadFailed: return .builtInModelCorrupt
        case .outOfMemory, .generationFailed: return .erroring(local.localizedDescription)
        case .unavailable: return nil
        }
    }

    var title: String {
        switch self {
        case .builtInModelMissing: return "The AI model isn't downloaded"
        case .builtInModelCorrupt: return "The AI model couldn't be loaded"
        case .erroring: return "The AI engine hit a problem"
        }
    }

    var message: String {
        switch self {
        case .erroring(let detail):
            return detail
        case .builtInModelMissing:
            return "Aletheia's AI model downloads once. Download it and Aletheia will retry your request."
        case .builtInModelCorrupt:
            return "The downloaded AI model file appears to be damaged or incomplete. Re-download it and Aletheia will retry your request."
        }
    }

    var action: Action {
        switch self {
        case .erroring: return .retry
        case .builtInModelMissing, .builtInModelCorrupt: return .downloadBuiltInModel
        }
    }

    var actionTitle: String {
        if case .builtInModelCorrupt = self { return "Re-download Model" }
        switch action {
        case .downloadBuiltInModel: return "Download Model"
        case .retry: return "Try Again"
        }
    }

    /// Whether the caller should re-run the failed request once the action has
    /// succeeded.
    var retriesAfterAction: Bool { true }
}

/// A problem plus the technical detail behind it, so "Copy Details" can give
/// support more than the friendly message.
struct AIEngineIncident: Equatable {
    let problem: AIEngineProblem
    /// The underlying error, e.g. `loadFailed("bad gguf")`. Never includes
    /// prompt or transcript text.
    let technical: String

    static func from(error: Error) -> AIEngineIncident? {
        AIEngineProblem.from(error: error)
            .map { AIEngineIncident(problem: $0, technical: String(describing: error)) }
    }
}

/// The text "Copy Details" puts on the clipboard. Facts about the engine and
/// the app only: no patient names, notes, transcripts or questions.
enum AIEngineSupportReport {
    static func text(
        incident: AIEngineIncident,
        appVersion: String,
        macOS: String,
        backend: String,
        model: String
    ) -> String {
        [
            "Aletheia AI engine problem",
            "Problem: \(incident.problem.title)",
            "Detail: \(incident.problem.message)",
            "Technical: \(incident.technical)",
            "Backend: \(backend)",
            "Model: \(model)",
            "App version: \(appVersion)",
            "macOS: \(macOS)",
        ].joined(separator: "\n")
    }
}

/// What the banner asks the engine, as closures so the decision is unit-tested.
struct AIEngineProbe {
    /// The built-in engine is active; its only problem is a missing model.
    var isBuiltInBackend = true
    var builtInModelPresent: () -> Bool = { true }

    /// The problem to show, or nil when the engine is fine or isn't the built-in one.
    func problem() -> AIEngineProblem? {
        guard isBuiltInBackend else { return nil }
        return builtInModelPresent() ? nil : .builtInModelMissing
    }
}

/// The kinds of request a session can have waiting on the engine.
enum EngineRetryKind: Equatable {
    case note
    case chat
}

/// Requests to re-run once, after the user fixes the engine: at most one per
/// `Key`, so a progress note and a chat question that both failed are both
/// re-run, while a repeat failure of the same kind replaces its earlier request.
/// `takeAll` and `clear` both empty it, so a dismissed alert can't re-run a stale
/// request later.
struct PendingRetries<Key: Equatable, Value> {
    private var entries: [(key: Key, value: Value)] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func set(_ value: Value, for key: Key) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append((key, value))
        }
    }

    /// Everything waiting, in the order first requested, leaving it empty.
    mutating func takeAll() -> [Value] {
        defer { entries.removeAll() }
        return entries.map { $0.value }
    }

    mutating func clear() { entries.removeAll() }
}

extension Array where Element == ChatMessage {
    /// Removes the message with `id` and everything after it (the question and
    /// any partial answer), so a retry asks the question once.
    mutating func removeTurn(startingAt id: UUID) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        removeSubrange(index...)
    }
}
