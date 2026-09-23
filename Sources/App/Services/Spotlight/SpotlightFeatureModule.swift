import Foundation

/// Spotlight indexing as a `FeatureModule`: complete and working, but opt-in
/// and non-core (record → transcribe → summarize → notes → chat is the MVP),
/// so it ships from `.preview` rather than `.mvp`.
struct SpotlightFeatureModule: FeatureModule {
    /// Also usable as `SpotlightFeatureModule.id` at call sites that only need
    /// the identifier to query the registry, without constructing an instance.
    static let id = "spotlightIndexing"

    var id: String { Self.id }
    let title = "Spotlight Search"
    let tier: BuildTier = .preview
}
