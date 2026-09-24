import XCTest
@testable import Aletheia

/// The embedded llama.cpp "Built-in Model" backend is carved to `.dev`: a
/// must-have for production eventually, but staged and not yet stable. These pin
/// it out of the production and preview builds and into dev — against the real
/// composition root's catalog.
final class EmbeddedLlamaFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeEmbeddedLlama() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: EmbeddedLlamaFeatureModule.id))
    }

    func testPreviewBuildDoesNotIncludeEmbeddedLlama() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: EmbeddedLlamaFeatureModule.id))
    }

    func testDevBuildIncludesEmbeddedLlama() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: EmbeddedLlamaFeatureModule.id))
    }
}
