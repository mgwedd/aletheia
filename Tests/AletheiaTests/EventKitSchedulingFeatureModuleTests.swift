import XCTest
@testable import Aletheia

/// EventKit scheduling ("Remind Me" reminders + "Schedule Next Session" calendar
/// events) is carved to `.dev`: an optional convenience whose shared permission
/// flow has been unreliable. These pin it out of the production and preview
/// builds and into dev — against the real composition root's catalog.
final class EventKitSchedulingFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeScheduling() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: EventKitSchedulingFeatureModule.id))
    }

    func testPreviewBuildDoesNotIncludeScheduling() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: EventKitSchedulingFeatureModule.id))
    }

    func testDevBuildIncludesScheduling() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: EventKitSchedulingFeatureModule.id))
    }
}
