import CoreSpotlight
import XCTest
@testable import Aletheia

/// What the indexer asks the system index to do, without touching the real one.
final class SpotlightIndexerTests: XCTestCase {
    private final class FakeIndex: SearchableIndex {
        enum Call: Equatable { case delete(String), index([String]) }
        var calls: [Call] = []
        var items: [CSSearchableItem] = []
        var deleteError: Error?

        func deleteItems(inDomain domain: String, completion: @escaping (Error?) -> Void) {
            calls.append(.delete(domain))
            completion(deleteError)
        }

        func index(_ items: [CSSearchableItem], completion: @escaping (Error?) -> Void) {
            calls.append(.index(items.map(\.uniqueIdentifier)))
            self.items = items
            completion(nil)
        }
    }

    private func entry(_ id: String, title: String = "Title") -> SpotlightEntry {
        SpotlightEntry(
            uniqueIdentifier: id, title: title, contentDescription: "Description",
            keywords: ["k"], contentModificationDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testReplacingTheIndexClearsOurDomainThenIndexesTheEntries() {
        let fake = FakeIndex()
        SpotlightIndexer(index: fake).replaceIndex(with: [entry("a"), entry("b")])

        XCTAssertEqual(fake.calls, [.delete(SpotlightItemBuilder.domainIdentifier), .index(["a", "b"])],
                       "the old items are removed first, so a deleted patient does not linger")
        XCTAssertTrue(fake.items.allSatisfy { $0.domainIdentifier == SpotlightItemBuilder.domainIdentifier })
    }

    func testItemsCarryExactlyTheEntryMetadata() throws {
        let fake = FakeIndex()
        SpotlightIndexer(index: fake).replaceIndex(with: [entry("a", title: "J.D.")])

        let attributes = try XCTUnwrap(fake.items.first).attributeSet
        XCTAssertEqual(attributes.title, "J.D.")
        XCTAssertEqual(attributes.contentDescription, "Description")
        XCTAssertEqual(attributes.keywords, ["k"])
        XCTAssertEqual(attributes.contentModificationDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testReplacingWithNothingEmptiesTheIndexAndIndexesNothing() {
        let fake = FakeIndex()
        SpotlightIndexer(index: fake).replaceIndex(with: [])
        XCTAssertEqual(fake.calls, [.delete(SpotlightItemBuilder.domainIdentifier)])
    }

    func testClearRemovesOnlyOurDomain() {
        let fake = FakeIndex()
        SpotlightIndexer(index: fake).clear()
        XCTAssertEqual(fake.calls, [.delete(SpotlightItemBuilder.domainIdentifier)])
    }

    func testAFailedClearDoesNotStopTheNewEntriesBeingIndexed() {
        let fake = FakeIndex()
        fake.deleteError = NSError(domain: "test", code: 1)
        SpotlightIndexer(index: fake).replaceIndex(with: [entry("a")])
        XCTAssertEqual(fake.calls.last, .index(["a"]))
    }
}

/// Whether the app puts patients into the system-wide index is a privacy
/// decision: only with the feature built in, the user's opt-in, and nothing
/// locked; otherwise the index is emptied. Never more than initials and dates.
@MainActor
final class AppModelSpotlightTests: XCTestCase {
    private final class RecordingIndexer: SpotlightIndexing {
        var replaced: [[SpotlightEntry]] = []
        var clears = 0
        func replaceIndex(with entries: [SpotlightEntry]) { replaced.append(entries) }
        func clear() { clears += 1 }
    }

    private struct FixedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    private var root: URL!
    private var originalRoot: URL?
    private var originalEnabled = false
    private var defaultsName: String!
    private var indexer: RecordingIndexer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelSpotlightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalRoot = AppSettings.shared.dataRootURL
        originalEnabled = AppSettings.shared.spotlightIndexingEnabled
        AppSettings.shared.dataRootURL = root
        defaultsName = "AppModelSpotlightTests-\(UUID().uuidString)"
        indexer = RecordingIndexer()
    }

    override func tearDownWithError() throws {
        SessionSearch.setAppLocked(false)
        SessionSearch.index = SearchIndex()
        AppSettings.shared.spotlightIndexingEnabled = originalEnabled
        AppSettings.shared.dataRootURL = originalRoot
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(withSpotlight: Bool = true) -> AppModel {
        let root = self.root!
        let encryption = EncryptionManager(dataRootProvider: { root }, defaults: UserDefaults(suiteName: defaultsName)!)
        let registry = FeatureRegistry(modules: withSpotlight ? [SpotlightFeatureModule()] : [])
        let model = AppModel(
            settings: .shared, encryption: encryption, spotlightIndexer: indexer, featureRegistry: registry)
        model.diskProbe = FixedDisk()
        return model
    }

    func testOptedInAndUnlockedIndexesPatientsByInitialsOnly() throws {
        AppSettings.shared.spotlightIndexingEnabled = true
        let model = makeModel()
        _ = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        indexer.replaced = []

        model.reindexSpotlight()

        let entries = try XCTUnwrap(indexer.replaced.last)
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let text = ([entry.title, entry.contentDescription] + entry.keywords).joined(separator: " ")
            XCTAssertFalse(text.contains("Jane"), "a full name never reaches the system index: \(text)")
            XCTAssertFalse(text.contains("Doe"), text)
        }
    }

    func testNotOptedInEmptiesTheIndex() throws {
        AppSettings.shared.spotlightIndexingEnabled = false
        let model = makeModel()
        _ = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        indexer.clears = 0
        indexer.replaced = []

        model.reindexSpotlight()

        XCTAssertEqual(indexer.clears, 1)
        XCTAssertTrue(indexer.replaced.isEmpty, "nothing is indexed without the opt-in")
    }

    func testALockedAppEmptiesTheIndexEvenWhenOptedIn() throws {
        AppSettings.shared.spotlightIndexingEnabled = true
        let model = makeModel()
        _ = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        indexer.clears = 0
        indexer.replaced = []

        SessionSearch.setAppLocked(true)
        model.reindexSpotlight()

        XCTAssertEqual(indexer.clears, 1)
        XCTAssertTrue(indexer.replaced.isEmpty, "nothing is published behind the lock screen")
    }

    func testABuildWithoutTheFeatureEmptiesTheIndexEvenWhenOptedIn() throws {
        AppSettings.shared.spotlightIndexingEnabled = true
        let model = makeModel(withSpotlight: false)
        _ = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        indexer.clears = 0
        indexer.replaced = []

        model.reindexSpotlight()

        XCTAssertEqual(indexer.clears, 1)
        XCTAssertTrue(indexer.replaced.isEmpty)
    }

    func testTurningTheOptInOffAfterIndexingEmptiesTheIndex() throws {
        AppSettings.shared.spotlightIndexingEnabled = true
        let model = makeModel()
        _ = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        model.reindexSpotlight()
        XCTAssertFalse(try XCTUnwrap(indexer.replaced.last).isEmpty)

        AppSettings.shared.spotlightIndexingEnabled = false
        model.reindexSpotlight()

        XCTAssertGreaterThan(indexer.clears, 0)
    }
}
