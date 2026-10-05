// These tests compile only at the `.dev` tier — the same tier that compiles the
// App Intents surface and its module descriptor. The unit tests always run in
// the Debug config (which defines ALETHEIA_DEV), so they run here; a production
// build has neither the App Intents code nor this test.
#if ALETHEIA_DEV
import XCTest
@testable import Aletheia

/// App Intents (Siri / Shortcuts) is a `.dev`-tier feature that is *compiled out*
/// of production and preview builds (it can't be gated at runtime). These pin
/// that, even in a build where its code is present (dev), composing at a lower
/// tier does not surface it — and that the dev build does.
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
#endif
