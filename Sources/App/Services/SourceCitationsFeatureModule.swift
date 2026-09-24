import Foundation

/// Source citations in cross-session chat answers as a `FeatureModule`.
///
/// Complete and working — it appends a numbered "sources" footer to an answer so
/// the therapist can trace a claim back to the session it came from — but it's a
/// non-core enrichment on top of chat, so it ships from `.preview` rather than
/// `.production`.
///
/// Gating is at the one call site (`PatientChatView`), which uses the raw answer
/// instead of the decorated one when the module is absent. Context retrieval is
/// unchanged; only the visible citation footer is withheld.
struct SourceCitationsFeatureModule: FeatureModule {
    /// Also usable as `SourceCitationsFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an instance.
    static let id = "sourceCitations"

    var id: String { Self.id }
    let title = "Source Citations"
    let tier: BuildTier = .preview
}
