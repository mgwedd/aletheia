import Foundation

/// Live state of the local AI engine, as shown in the menu-bar status line.
/// Distinct from `ToolHealthCheck.Status` (ok/warning/failed) because the
/// menu bar also needs a `loading` phase for the moment before the first
/// poll completes — there's no "unknown yet" case to fall back on there.
enum EngineRunState: Equatable {
    /// First poll hasn't returned yet (menu just opened).
    case loading
    /// Engine reachable and the configured model is present — ready to use.
    case reachable(engineName: String, modelName: String)
    /// Engine reachable, but the configured model isn't downloaded yet.
    case reachableNoModel(engineName: String, modelName: String)
    /// Engine not reachable at all (e.g. Ollama isn't running).
    case unreachable(engineName: String)
}

/// A neutral stand-in for a status color, kept separate from `SwiftUI.Color`
/// so the state→presentation mapping below is plain, framework-free logic
/// that unit tests can check without importing SwiftUI.
enum EngineStatusTint: Equatable {
    case green
    case yellow
    case red
    case gray
}

/// What the menu bar actually renders for a given engine state: an SF Symbol,
/// a one-line label, and a tint. Mirrors the checkmark/triangle/xmark +
/// green/yellow/red convention `SettingsView.statusIcon` already uses for
/// `ToolHealthCheck.Status`, so the engine line reads the same way.
struct EngineStatusPresentation: Equatable {
    let symbolName: String
    let label: String
    let tint: EngineStatusTint

    /// Pure mapping from engine state to what's on screen. No I/O, no
    /// environment reads — safe to unit test directly.
    static func present(_ state: EngineRunState) -> EngineStatusPresentation {
        switch state {
        case .loading:
            return EngineStatusPresentation(
                symbolName: "circle.dotted",
                label: "Checking AI engine…",
                tint: .gray
            )
        case let .reachable(engineName, modelName):
            return EngineStatusPresentation(
                symbolName: "checkmark.circle.fill",
                label: "\(engineName) running · \(modelName)",
                tint: .green
            )
        case let .reachableNoModel(engineName, modelName):
            return EngineStatusPresentation(
                symbolName: "exclamationmark.triangle.fill",
                label: "\(engineName) running · \(modelName) not downloaded",
                tint: .yellow
            )
        case let .unreachable(engineName):
            return EngineStatusPresentation(
                symbolName: "xmark.circle.fill",
                label: "\(engineName) not reachable",
                tint: .red
            )
        }
    }
}

/// Probes the same backend/assistant seam `ToolHealth.ollamaCheck` uses (no
/// new health check) so the menu bar's engine line and the Settings/setup
/// checklist status agree. Deliberately stateless and read-only — nothing
/// here writes to `AppSettings` or persists anything — so the caller (the
/// menu bar view) just holds the returned `EngineRunState` in its own
/// `@State` and re-probes on a timer.
@MainActor
enum EngineStatusProbe {
    /// Re-probes engine reachability and model presence. Cheap: just the
    /// existing local health check (an HTTP call to 127.0.0.1 for Ollama, or
    /// a local file/runtime check for the embedded engine) — no new network
    /// calls and nothing that leaves this Mac.
    static func currentState(settings: AppSettings, integrations: Integrations) async -> EngineRunState {
        let backend = integrations.effectiveAssistantBackend
        let resolvedEngineName = engineName(for: backend)
        let resolvedModelName = modelName(for: backend, settings: settings)
        let assistant = integrations.makeAssistant()

        guard await assistant.isReachable() else {
            return .unreachable(engineName: resolvedEngineName)
        }
        let hasModel = await assistant.hasModel(resolvedModelName)
        return hasModel
            ? .reachable(engineName: resolvedEngineName, modelName: resolvedModelName)
            : .reachableNoModel(engineName: resolvedEngineName, modelName: resolvedModelName)
    }

    /// The name shown for whichever backend `Integrations.makeAssistant()`
    /// actually resolves to. Pure and `nonisolated` — no `AppSettings` or
    /// `Integrations` instance involved — so it's callable (and testable)
    /// without hopping to the main actor.
    nonisolated static func engineName(for backend: AssistantBackend) -> String {
        switch backend {
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama, .automatic: return "Ollama"
        case .localLlama: return "Built-in engine"
        }
    }

    /// The active model name for whichever backend is running. The embedded
    /// engine's model choice lives in `settings.llamaModel`; every other
    /// backend uses the shared Ollama model tag. `nonisolated` for the same
    /// reason as `engineName(for:)`.
    nonisolated static func modelName(for backend: AssistantBackend, settings: AppSettings) -> String {
        switch backend {
        case .localLlama: return settings.llamaModel.shortName
        case .appleIntelligence, .ollama, .automatic: return settings.ollamaModelName
        }
    }
}
