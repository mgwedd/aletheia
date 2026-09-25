import Foundation

/// Where the Ollama engine stands, from "never installed" through to "ready to
/// answer". Pulled out as a pure state machine — no I/O, no `NSWorkspace`, no
/// networking — so the setup checklist's decision of *which* one-click fix to
/// offer (open the download page vs. launch the already-installed app vs.
/// nothing, because it's already coming up) is unit-tested without a Mac.
///
/// ```
/// notInstalled ──install──> installedNotRunning ──launch──> starting
///                                                                │
///                                                     reachable  ▼
///                                                    ┌─── running ───┐
///                                          no model   │               │ has model
///                                                      ▼               ▼
///                                              modelMissing         ready
/// ```
enum OllamaEngineState: Equatable {
    /// Ollama.app isn't on this Mac at all (or wasn't found by any of the
    /// lookups `OllamaAppLocator` tries).
    case notInstalled
    /// The app is installed but its HTTP server isn't answering — the common
    /// "downloaded once, quit, never came back" case this fixes.
    case installedNotRunning
    /// We just asked `NSWorkspace` to open it and are polling for it to come up.
    case starting
    /// The server answered, but whether the configured model is present isn't
    /// known yet (a caller hasn't checked `hasModel`).
    case running
    /// Reachable, but the configured model hasn't been pulled yet.
    case modelMissing
    /// Reachable and the configured model is present — fully ready.
    case ready

    /// Pure mapping from the raw facts to a state. `hasModel` is `nil` when
    /// that hasn't been checked yet (e.g. right after a successful launch,
    /// before the next health-check pass).
    static func classify(installed: Bool, isLaunching: Bool, reachable: Bool, hasModel: Bool?) -> OllamaEngineState {
        guard installed else { return .notInstalled }
        if isLaunching { return .starting }
        guard reachable else { return .installedNotRunning }
        guard let hasModel else { return .running }
        return hasModel ? .ready : .modelMissing
    }

    /// Whether this state means the therapist has something to do before AI
    /// features work — as opposed to `.starting`/`.running`, which are just
    /// "give it a moment" states with nothing to click.
    var needsAction: Bool {
        switch self {
        case .notInstalled, .installedNotRunning, .modelMissing: return true
        case .starting, .running, .ready: return false
        }
    }
}
