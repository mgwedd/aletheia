import XCTest
@testable import Aletheia

/// Source citations (the numbered "sources" footer on chat answers) ship in
/// every tier. These pin that against the real composition root's catalog, so
/// a later demotion is a deliberate change.
final class SourceCitationsFeatureModuleTests: XCTestCase {
    func testEveryBuildIncludesCitations() {
        for tier in [BuildTier.production, .preview, .dev] {
            let registry = FeatureRegistry.compose(tier: tier, from: FeatureRegistry.allModules)
            XCTAssertTrue(registry.contains(id: SourceCitationsFeatureModule.id), "missing at \(tier)")
        }
    }
}
