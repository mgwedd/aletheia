import Foundation

/// A self-contained unit of app functionality that a build can include or leave
/// out.
///
/// This is the seam of the modular ("cellular") architecture: a feature reaches
/// the rest of the app only through this protocol, never into another module's
/// internals, so a module that is absent — deferred to a higher tier, or
/// withheld because it's broken — leaves a clean gap rather than collateral
/// damage on the UI.
///
/// This first cut is deliberately minimal: identity and the build tier the
/// feature ships in. The **contribution points** a module uses to surface itself
/// (a Settings section, a first-run step, a menu/toolbar item, a session-lifecycle
/// hook) are added here as each feature is peeled into a module, so their shapes
/// are designed against real use instead of guessed up front. See
/// `FeatureRegistry` for how the enabled modules are composed for a build.
protocol FeatureModule {
    /// Stable identifier for the module. Also the key any per-feature state or
    /// diagnostics hang off. Never rename one once shipped; ids must be unique
    /// across the registry (`FeatureRegistry` drops later duplicates).
    var id: String { get }

    /// Human-readable name, for an "About this build" / diagnostics listing.
    var title: String { get }

    /// The lowest `BuildTier` this module ships in. A build at tier T includes
    /// the module when `tier <= T`.
    var tier: BuildTier { get }
}
