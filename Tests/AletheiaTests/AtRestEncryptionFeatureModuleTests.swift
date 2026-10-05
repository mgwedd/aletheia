import XCTest
@testable import Aletheia

/// At-rest encryption ships from `.dev` only — this area has a history of
/// being glitchy, so it isn't surfaced to testers (`.preview`) yet, let alone
/// the clinician (`.production`). These pin that against the real composition root's
/// catalog.
final class AtRestEncryptionFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeAtRestEncryption() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: AtRestEncryptionFeatureModule.id))
    }

    func testPreviewBuildDoesNotIncludeAtRestEncryption() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: AtRestEncryptionFeatureModule.id))
    }

    func testDevBuildIncludesAtRestEncryption() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: AtRestEncryptionFeatureModule.id))
    }
}
