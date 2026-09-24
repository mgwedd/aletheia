import XCTest
@testable import Aletheia

/// `FeatureRegistry.compose` is the one place that decides what's in a build.
/// These pin its three jobs: tier filtering, id de-duplication, and stable
/// ordering — plus lookup.
final class FeatureRegistryTests: XCTestCase {
    private struct MockModule: FeatureModule {
        let id: String
        let title: String
        let tier: BuildTier
    }

    private let all: [FeatureModule] = [
        MockModule(id: "chat", title: "Chat", tier: .production),
        MockModule(id: "notes", title: "Notes", tier: .production),
        MockModule(id: "search", title: "Search", tier: .preview),
        MockModule(id: "encryption", title: "Encryption", tier: .preview),
        MockModule(id: "spotlight", title: "Spotlight", tier: .dev),
    ]

    func testProductionBuildComposesOnlyProductionModules() {
        let registry = FeatureRegistry.compose(tier: .production, from: all)
        XCTAssertEqual(Set(registry.ids), ["chat", "notes"])
    }

    func testPreviewBuildAddsPreviewModulesButNotDev() {
        let registry = FeatureRegistry.compose(tier: .preview, from: all)
        XCTAssertEqual(Set(registry.ids), ["chat", "notes", "search", "encryption"])
        XCTAssertFalse(registry.contains(id: "spotlight"))
    }

    func testDevBuildComposesEverything() {
        let registry = FeatureRegistry.compose(tier: .dev, from: all)
        XCTAssertEqual(registry.modules.count, all.count)
        XCTAssertTrue(registry.contains(id: "spotlight"))
    }

    func testDuplicateIdsKeepTheFirstDeclaration() {
        let dupes: [FeatureModule] = [
            MockModule(id: "chat", title: "Chat (real)", tier: .production),
            MockModule(id: "chat", title: "Chat (shadow)", tier: .production),
        ]
        let registry = FeatureRegistry.compose(tier: .production, from: dupes)
        XCTAssertEqual(registry.ids, ["chat"])
        XCTAssertEqual(registry.module(id: "chat")?.title, "Chat (real)")
    }

    func testOrderingIsByTierThenTitleCaseInsensitive() {
        let unordered: [FeatureModule] = [
            MockModule(id: "z", title: "zebra", tier: .preview),
            MockModule(id: "a", title: "Apple", tier: .preview),
            MockModule(id: "core", title: "Xylophone", tier: .production),
        ]
        let registry = FeatureRegistry.compose(tier: .dev, from: unordered)
        // production module first regardless of title; then preview modules A→Z.
        XCTAssertEqual(registry.ids, ["core", "a", "z"])
    }

    func testLookupAndMembership() {
        let registry = FeatureRegistry.compose(tier: .preview, from: all)
        XCTAssertTrue(registry.contains(id: "search"))
        XCTAssertNil(registry.module(id: "spotlight"), "a dev module isn't in a preview build")
        XCTAssertEqual(registry.module(id: "notes")?.title, "Notes")
    }

    func testEmptyCatalogComposesEmptyRegistry() {
        let registry = FeatureRegistry.compose(tier: .dev, from: [])
        XCTAssertTrue(registry.modules.isEmpty)
        XCTAssertFalse(registry.contains(id: "anything"))
    }
}
