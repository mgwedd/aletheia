import XCTest
@testable import Aletheia

/// The embedded llama.cpp "Built-in Model" backend is first-class: every build
/// tier offers it. Checked against the real composition root's catalog.
final class EmbeddedLlamaFeatureModuleTests: XCTestCase {
    func testEveryTierIncludesEmbeddedLlama() {
        for tier in BuildTier.allCases {
            let registry = FeatureRegistry.compose(tier: tier, from: FeatureRegistry.allModules)
            XCTAssertTrue(registry.contains(id: EmbeddedLlamaFeatureModule.id), "\(tier)")
        }
    }
}
