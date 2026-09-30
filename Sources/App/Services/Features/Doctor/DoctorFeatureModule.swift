import Foundation

/// "Aletheia Doctor" as a `FeatureModule`: an on-demand health check that tells
/// the therapist, in plain language, whether Aletheia can safely save her notes —
/// and what to do when it can't. It ships in **production**: a data-safety
/// diagnostic is exactly what a clinician needs when the database won't open, so
/// it is part of the thin core, not a tester-only extra.
///
/// ```
///   DoctorRunner ──(injected probes)──▶ [DoctorCheck] ──▶ DoctorReport
///        │                                                    │
///   LiveDoctorProbes (disk, SQLite,                  DoctorView (window) /
///   keystore, snapshots, ToolHealth)                 PHI-safe "Copy report"
/// ```
///
/// The checks themselves are pure and unit-tested with stub probes; the only
/// I/O lives in `LiveDoctorProbes`. Nothing here leaves the Mac: the sole network
/// touch is the existing Ollama reachability check, and only when Ollama's
/// address is loopback.
struct DoctorFeatureModule: FeatureModule {
    /// Also usable as `DoctorFeatureModule.id` at call sites that only need the
    /// identifier to query the registry, without constructing an instance.
    static let id = "doctor"

    /// The identifier of the Doctor window scene (`AletheiaApp`), used with
    /// `openWindow(id:)` from Settings, the Help menu and the error banner.
    static let windowID = "doctor"

    var id: String { Self.id }
    let title = "Aletheia Doctor"
    let tier: BuildTier = .production
}
