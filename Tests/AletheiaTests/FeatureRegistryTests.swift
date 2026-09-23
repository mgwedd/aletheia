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
        MockModule(id: "chat", title: "Chat", tier: .mvp),
        MockModule(id: "notes", title: "Notes", tier: .mvp),
        MockModule(id: "search", title: "Search", tier: .preview),
        MockModule(id: "encryption", title: "Encryption", tier: .preview),
        MockModule(id: "spotlight", title: "Spotlight", tier: .dev),
    ]

    func testMvpBuildComposesOnlyMvpModules() {
        let registry = FeatureRegistry.compose(tier: .mvp, from: all)
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
            MockModule(id: "chat", title: "Chat (real)", tier: .mvp),
            MockModule(id: "chat", title: "Chat (shadow)", tier: .mvp),
        ]
        let registry = FeatureRegistry.compose(tier: .mvp, from: dupes)
        XCTAssertEqual(registry.ids, ["chat"])
        XCTAssertEqual(registry.module(id: "chat")?.title, "Chat (real)")
    }

    func testOrderingIsByTierThenTitleCaseInsensitive() {
        let unordered: [FeatureModule] = [
            MockModule(id: "z", title: "zebra", tier: .preview),
            MockModule(id: "a", title: "Apple", tier: .preview),
            MockModule(id: "core", title: "Xylophone", tier: .mvp),
        ]
        let registry = FeatureRegistry.compose(tier: .dev, from: unordered)
        // mvp module first regardless of title; then preview modules A→Z.
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
