import Foundation

/// Spotlight indexing as a `FeatureModule`: complete and working, but opt-in
/// and non-core (record → transcribe → summarize → notes → chat is the MVP),
/// so it ships from `.preview` rather than `.mvp`.
public struct SpotlightFeatureModule: FeatureModule {
    /// Also usable as `SpotlightFeatureModule.id` at call sites that only need
    /// the identifier to query the registry, without constructing an instance.
    public static let id = "spotlightIndexing"

    public var id: String { Self.id }
    public let title = "Spotlight Search"
    public let tier: BuildTier = .preview

    public init() {}
}
