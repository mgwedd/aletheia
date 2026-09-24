import XCTest
@testable import Aletheia

/// Chat "suggested questions" starter chips are carved to `.preview`: complete
/// but a non-core convenience. These pin the module out of the production build
/// and into preview/dev — against the real composition root's catalog.
final class SuggestedQuestionsFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeSuggestedQuestions() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: SuggestedQuestionsFeatureModule.id))
    }

    func testPreviewBuildIncludesSuggestedQuestions() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SuggestedQuestionsFeatureModule.id))
    }

    func testDevBuildIncludesSuggestedQuestions() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: SuggestedQuestionsFeatureModule.id))
    }
}
