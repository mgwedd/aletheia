import XCTest
@testable import Aletheia

/// Spotlight indexing is the first feature peeled into a `FeatureModule`. It's
/// complete and working but non-core, so it should ship from `.preview`, not
/// `.production` — these pin that against the real composition root's catalog.
final class SpotlightFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeSpotlight() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: SpotlightFeatureModule.id))
    }

    func testPreviewBuildIncludesSpotlight() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SpotlightFeatureModule.id))
    }

    func testDevBuildIncludesSpotlight() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SpotlightFeatureModule.id))
    }
}
