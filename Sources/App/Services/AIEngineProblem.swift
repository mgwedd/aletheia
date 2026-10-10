import Foundation

/// What went wrong with the local AI engine, in the terms a therapist can act
/// on, and the one next step to offer. Pure — no I/O — so the mapping from an
/// error to "which button do we show" is unit-tested without a Mac.
///
/// ```
/// OllamaError.notReachable ─┬─ app not installed ─▶ notInstalled     [Get Ollama]
///                           └─ app installed ─────▶ notRunning       [Start Ollama]
/// OllamaError.modelNotFound ───────────────────────▶ modelMissing     [Download model]
/// OllamaError.badResponse ─────────────────────────▶ erroring         [Try again]
/// anything else ───────────────────────────────────▶ nil (normal error alert)
/// ```
enum AIEngineProblem: Equatable {
    case notInstalled
    case notRunning
    case modelMissing(String)
    case erroring(String)

    enum Action: Equatable {
        case getOllama
        case startOllama
        case downloadModel(String)
        case retry
    }

    static func from(error: Error, ollamaInstalled: Bool) -> AIEngineProblem? {
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
        case .modelMissing: return "The AI model isn't downloaded"
        case .erroring: return "The local AI engine hit a problem"
        }
    }

    var message: String {
        switch self {
        case .notInstalled:
            return "Aletheia's AI runs on Ollama, a free engine that stays on this Mac. Install it once, then try again."
        case .notRunning:
            return "Ollama is installed but not running. Start it and Aletheia will retry your request."
        case .modelMissing(let name):
            return "The “\(name)” model hasn't been downloaded yet. Download it and Aletheia will retry your request."
        case .erroring(let detail):
            return detail
        }
    }

    var action: Action {
        switch self {
        case .notInstalled: return .getOllama
        case .notRunning: return .startOllama
        case .modelMissing(let name): return .downloadModel(name)
        case .erroring: return .retry
        }
    }

    var actionTitle: String {
        switch action {
        case .getOllama: return "Get Ollama"
        case .startOllama: return "Start Ollama"
        case .downloadModel: return "Download Model"
        case .retry: return "Try Again"
        }
    }

    /// Whether the caller should re-run the failed request once the action has
    /// succeeded. Installing Ollama happens in the browser and the app, so there
    /// is nothing to wait for and the user retries themselves.
    var retriesAfterAction: Bool {
        switch action {
        case .getOllama: return false
        case .startOllama, .downloadModel, .retry: return true
        }
    }
}
