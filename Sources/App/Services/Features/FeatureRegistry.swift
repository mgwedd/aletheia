import Foundation

/// The composition root: turns the full catalog of known feature modules into
/// the set a particular build actually ships.
///
/// Composition is a pure function of (target tier, all known modules):
///
/// ```
///   compose(tier: .current, from: allModules)
///        │
///        ├─ keep modules whose own tier ≤ target tier
///        ├─ drop duplicate ids (first declaration wins)
///        └─ order deterministically (tier, then title)
///        ▼
///   FeatureRegistry — the enabled modules for this build
/// ```
///
/// Keeping the rule here, pure and testable, means there is exactly one place
/// that decides what's in a build, and the UI never has to ask "is this feature
/// present?" in an ad-hoc way — it asks the registry.
struct FeatureRegistry {
    /// The enabled modules for this build, deduped and deterministically ordered.
    let modules: [FeatureModule]

    /// Compose the registry for a target tier from every known module.
    /// - Keeps modules included at `tier` (`module.tier <= tier`).
    /// - Drops later duplicates of an id, keeping the first declaration.
    /// - Orders by tier then title, so the set is stable across launches.
    static func compose(tier: BuildTier, from all: [FeatureModule]) -> FeatureRegistry {
        var seen = Set<String>()
        let included = all
            .filter { tier.includes($0.tier) }
            .filter { seen.insert($0.id).inserted } // first id wins
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        return FeatureRegistry(modules: included)
    }

    /// Whether a module with `id` is present in this build.
    func contains(id: String) -> Bool { modules.contains { $0.id == id } }

    /// The module with `id`, if present.
    func module(id: String) -> FeatureModule? { modules.first { $0.id == id } }

    /// The enabled module ids, in registry order.
    var ids: [String] { modules.map(\.id) }
}

extension FeatureRegistry {
    /// Every feature module the app knows about, regardless of build tier.
    /// `compose(tier:from:)` filters this down to what a given build ships.
    /// Add each new module here as it's peeled out.
    static let allModules: [FeatureModule] = [
        SpotlightFeatureModule(),
        AtRestEncryptionFeatureModule(),
        EventKitSchedulingFeatureModule()
    ]
}
