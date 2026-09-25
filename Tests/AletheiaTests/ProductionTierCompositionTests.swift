import XCTest
@testable import Aletheia

/// A guard on the production build surface itself: what `FeatureRegistry`
/// actually composes from the real `FeatureRegistry.allModules` catalog, not a
/// mock one. Where `FeatureRegistryTests` pins the `compose(tier:from:)`
/// algorithm in the abstract, this pins the concrete catalog — so a module
/// mistakenly declared (or later edited) to a lower tier than intended is
/// caught here, against production, rather than discovered by a clinician.
///
/// ```
///   allModules ──compose(.production)──▶ registry ⊆ compose(.preview) ⊆ compose(.dev)
/// ```
final class ProductionTierCompositionTests: XCTestCase {
    private var production: FeatureRegistry { FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules) }
    private var preview: FeatureRegistry { FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules) }
    private var dev: FeatureRegistry { FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules) }

    // MARK: Derived expectation — never a hardcoded id list

    /// The production set is exactly "every module in the catalog whose own
    /// tier is `.production`" — derived from the catalog itself, so this stays
    /// correct as modules are added without editing this test.
    func testProductionRegistryIsExactlyTheProductionTierModules() {
        let expectedIds = Set(FeatureRegistry.allModules.filter { $0.tier == .production }.map(\.id))
        XCTAssertEqual(Set(production.ids), expectedIds)
    }

    // MARK: Specific known facts — pinned in addition to the derived check

    func testEmbeddedLlamaIsAbsentFromProduction() {
        XCTAssertFalse(production.contains(id: EmbeddedLlamaFeatureModule.id))
    }

    func testEmbeddedLlamaIsPresentInDev() {
        XCTAssertTrue(dev.contains(id: EmbeddedLlamaFeatureModule.id))
    }

    // MARK: Every non-production module is held out of production, present at its own tier

    /// For every module the catalog declares `.preview` or `.dev`: it must not
    /// leak into the production registry, and it must show up once its own
    /// tier is reached. Iterating the real catalog (rather than a fixed list)
    /// means a new `.preview`/`.dev` module is covered automatically.
    func testEveryNonProductionModuleIsGatedOutOfProductionAndPresentAtItsOwnTier() {
        let nonProduction = FeatureRegistry.allModules.filter { $0.tier != .production }
        XCTAssertFalse(nonProduction.isEmpty, "expected at least one preview/dev module to guard — update this test if the catalog changes shape")

        for module in nonProduction {
            XCTAssertFalse(production.contains(id: module.id), "\(module.id) is tier \(module.tier) but leaked into production")

            let ownTierRegistry = FeatureRegistry.compose(tier: module.tier, from: FeatureRegistry.allModules)
            XCTAssertTrue(ownTierRegistry.contains(id: module.id), "\(module.id) should be present once its own tier (\(module.tier)) is reached")
        }
    }

    // MARK: Nesting invariant

    /// `production ⊆ preview ⊆ dev` for the real catalog — the same guarantee
    /// `BuildTier.includes` promises in the abstract, checked here against
    /// what actually gets registered.
    func testTiersNestForTheRealCatalog() {
        let productionIds = Set(production.ids)
        let previewIds = Set(preview.ids)
        let devIds = Set(dev.ids)

        XCTAssertTrue(productionIds.isSubset(of: previewIds))
        XCTAssertTrue(previewIds.isSubset(of: devIds))
    }
}
