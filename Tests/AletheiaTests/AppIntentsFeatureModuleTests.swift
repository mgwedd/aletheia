import XCTest
@testable import Aletheia

/// Siri / Shortcuts (App Intents) is carved to `.dev`: experimental, PHI-adjacent,
/// and leaning on a permission flow that's been unreliable. These pin that it's
/// absent from the production and preview builds and present only in dev — against
/// the real composition root's catalog.
final class AppIntentsFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeAppIntents() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: AppIntentsFeatureModule.id))
    }

    func testPreviewBuildDoesNotIncludeAppIntents() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: AppIntentsFeatureModule.id))
    }

    func testDevBuildIncludesAppIntents() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: AppIntentsFeatureModule.id))
    }
}
