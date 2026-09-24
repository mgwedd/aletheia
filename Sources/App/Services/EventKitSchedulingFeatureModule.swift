import Foundation

/// EventKit scheduling — the "Remind Me" follow-up reminders and the
/// "Schedule Next Session" calendar events — as a single `FeatureModule`.
///
/// Both are optional conveniences that share the EventKit permission flow, and
/// that flow has been unreliable in the setup wizard (grant appears to freeze,
/// then the feature errors — see the reported bug). Until it's solid, this ships
/// developer-build-only (`.dev`) and is absent from production and preview.
///
/// Gating covers every place the surface appears: the session toolbar controls
/// ("Remind Me" / "Schedule Next…") and the setup-wizard Calendar/Reminders
/// permission steps (`ToolHealth.runAllChecks(includeScheduling:)`). A build
/// without this module simply never asks for Calendar/Reminders access and never
/// offers the buttons — a clean gap, and one fewer permission prompt to fail on.
struct EventKitSchedulingFeatureModule: FeatureModule {
    /// Also usable as `EventKitSchedulingFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an instance.
    static let id = "eventKitScheduling"

    var id: String { Self.id }
    let title = "Reminders & Calendar"
    let tier: BuildTier = .dev
}
