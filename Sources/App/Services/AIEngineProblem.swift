import Foundation

/// What went wrong with the local AI engine, in the terms a therapist can act
/// on, and the one next step to offer. Pure — no I/O — so the mapping from an
/// error to "which button do we show" is unit-tested without a Mac.
///
/// ```
/// OllamaError.notReachable ─┬─ app not installed ─▶ notInstalled        [Get Ollama]
///                           └─ app installed ─────▶ notRunning          [Start Ollama]
/// OllamaError.modelNotFound ───────────────────────▶ modelMissing        [Download model]
/// OllamaError.badResponse ─────────────────────────▶ erroring            [Try again]
/// LocalLLMEngineError.modelNotDownloaded ──────────▶ builtInModelMissing [Download model]
/// LocalLLMEngineError.loadFailed ──────────────────▶ builtInModelCorrupt [Re-download model]
/// LocalLLMEngineError.outOfMemory / generationFailed ▶ erroring          [Try again]
/// anything else ───────────────────────────────────▶ nil (normal error alert)
/// ```
enum AIEngineProblem: Equatable {
    case notInstalled
    case notRunning
    case modelMissing(String)
    case erroring(String)
    /// The built-in engine's model isn't downloaded yet.
    case builtInModelMissing
    /// The built-in engine's model file failed to load (corrupt or incomplete).
    case builtInModelCorrupt

    enum Action: Equatable {
        case getOllama
        case startOllama
        case downloadModel(String)
        case downloadBuiltInModel
        case retry
    }

    /// From a health check rather than a failed request: what, if anything, is
    /// wrong with the engine right now. `nil` when it is ready, still starting,
    /// or reachable with the model not yet checked.
    static func from(state: OllamaEngineState, modelName: String) -> AIEngineProblem? {
        switch state {
        case .notInstalled: return .notInstalled
        case .installedNotRunning: return .notRunning
        case .modelMissing: return .modelMissing(modelName)
        case .starting, .running, .ready: return nil
        }
    }

    static func from(error: Error, ollamaInstalled: Bool) -> AIEngineProblem? {
        if let local = error as? LocalLLMEngineError {
            switch local {
            case .modelNotDownloaded: return .builtInModelMissing
            case .loadFailed: return .builtInModelCorrupt
            case .outOfMemory, .generationFailed: return .erroring(local.localizedDescription)
            case .unavailable: return nil
            }
        }
        guard let ollama = error as? OllamaError else { return nil }
        switch ollama {
        case .notReachable: return ollamaInstalled ? .notRunning : .notInstalled
        case .modelNotFound(let name): return .modelMissing(name)
        case .badResponse: return .erroring(ollama.localizedDescription)
        }
    }

    var title: String {
        switch self {
        case .notInstalled: return "The local AI engine isn't installed"
        case .notRunning: return "The local AI engine isn't running"
        case .modelMissing, .builtInModelMissing: return "The AI model isn't downloaded"
        case .builtInModelCorrupt: return "The AI model couldn't be loaded"
        case .erroring: return "The local AI engine hit a problem"
        }
    }

    var message: String {
        switch self {
        case .notInstalled:
            return "Aletheia's AI runs on Ollama, a free engine. Install it once, then try again."
        case .notRunning:
            return "Ollama is installed but not running. Start it and Aletheia will retry your request."
        case .modelMissing(let name):
            return "The “\(name)” model hasn't been downloaded yet. Download it and Aletheia will retry your request."
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
        case .notInstalled: return .getOllama
        case .notRunning: return .startOllama
        case .modelMissing(let name): return .downloadModel(name)
        case .erroring: return .retry
        case .builtInModelMissing, .builtInModelCorrupt: return .downloadBuiltInModel
        }
    }

    var actionTitle: String {
        if case .builtInModelCorrupt = self { return "Re-download Model" }
        switch action {
        case .getOllama: return "Get Ollama"
        case .startOllama: return "Start Ollama"
        case .downloadModel, .downloadBuiltInModel: return "Download Model"
        case .retry: return "Try Again"
        }
    }

    /// Whether the caller should re-run the failed request once the action has
    /// succeeded. Installing Ollama happens in the browser and the app, so there
    /// is nothing to wait for and the user retries themselves.
    var retriesAfterAction: Bool {
        switch action {
        case .getOllama: return false
        case .startOllama, .downloadModel, .downloadBuiltInModel, .retry: return true
        }
    }
}

/// A problem plus the technical detail behind it, so "Copy Details" can give
/// support more than the friendly message.
struct AIEngineIncident: Equatable {
    let problem: AIEngineProblem
    /// The underlying error, e.g. `modelNotFound("qwen2.5:7b")`. Never includes
    /// prompt or transcript text.
    let technical: String

    static func from(error: Error, ollamaInstalled: Bool) -> AIEngineIncident? {
        AIEngineProblem.from(error: error, ollamaInstalled: ollamaInstalled)
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
    var isOllamaBackend: Bool
    var modelName: String
    var isReachable: () async -> Bool
    var hasModel: (String) async -> Bool
    var isInstalled: () -> Bool
    /// The built-in engine is active; its only problem is a missing model.
    var isBuiltInBackend = false
    var builtInModelPresent: () -> Bool = { true }

    /// The problem to show, or nil when the engine is fine or is neither
    /// Ollama nor the built-in engine.
    func problem() async -> AIEngineProblem? {
        if isBuiltInBackend { return builtInModelPresent() ? nil : .builtInModelMissing }
        guard isOllamaBackend else { return nil }
        let reachable = await isReachable()
        var model: Bool?
        if reachable { model = await hasModel(modelName) }
        // A running Ollama counts as installed even if the app bundle isn't found.
        let installed = reachable ? true : isInstalled()
        let state = OllamaEngineState.classify(installed: installed, isLaunching: false, reachable: reachable, hasModel: model)
        return AIEngineProblem.from(state: state, modelName: modelName)
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
