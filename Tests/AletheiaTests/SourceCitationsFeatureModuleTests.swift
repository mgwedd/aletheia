import XCTest
@testable import Aletheia

/// Source citations (the numbered "sources" footer on chat answers) are carved to
/// `.preview`: complete but a non-core enrichment. These pin the module out of
/// the production build and into preview/dev — against the real composition
/// root's catalog.
final class SourceCitationsFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeCitations() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: SourceCitationsFeatureModule.id))
    }

    func testPreviewBuildIncludesCitations() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SourceCitationsFeatureModule.id))
    }

    func testDevBuildIncludesCitations() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SourceCitationsFeatureModule.id))
    }
}
