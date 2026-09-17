import XCTest
@testable import SessionNotes

final class StoreSchemaTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var metaURL: URL {
        tempRoot.appendingPathComponent(DataSchema.metadataFileName)
    }

    private func writeMeta(version: Int) throws {
        let data = try JSONEncoder().encode(StoreMetadata(schemaVersion: version, lastWrittenBy: "test"))
        try data.write(to: metaURL)
    }

    private func readMetaVersion() throws -> Int {
        let data = try Data(contentsOf: metaURL)
        return try JSONDecoder().decode(StoreMetadata.self, from: data).schemaVersion
    }

    func testFreshFolderIsStampedAtCurrentVersion() throws {
        let store = Store(root: tempRoot)
        XCTAssertEqual(store.schemaCompatibility, .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
        XCTAssertEqual(try readMetaVersion(), DataSchema.currentVersion)
    }

    func testNewerDataIsFlaggedAndNotRewritten() throws {
        try writeMeta(version: DataSchema.currentVersion + 5)
        let store = Store(root: tempRoot)
        XCTAssertEqual(
            store.schemaCompatibility,
            .needsNewerApp(dataVersion: DataSchema.currentVersion + 5, appVersion: DataSchema.currentVersion)
        )
        // Must NOT have downgraded the stamp — that would risk clobbering
        // data written by a newer app.
        XCTAssertEqual(try readMetaVersion(), DataSchema.currentVersion + 5)
    }

    func testOlderDataIsUpgradedAndRestamped() throws {
        try writeMeta(version: 0)
        let store = Store(root: tempRoot)
        XCTAssertEqual(store.schemaCompatibility, .upgraded(fromVersion: 0))
        XCTAssertEqual(try readMetaVersion(), DataSchema.currentVersion)
    }

    func testSameVersionIsOk() throws {
        try writeMeta(version: DataSchema.currentVersion)
        let store = Store(root: tempRoot)
        XCTAssertEqual(store.schemaCompatibility, .ok)
    }

    func testReconcileDoesNotDisturbPatientData() throws {
        let store = Store(root: tempRoot)
        _ = try store.createPatient(name: "Jane Doe")
        // Re-opening the same folder still lists the patient and stays ok.
        let reopened = Store(root: tempRoot)
        XCTAssertEqual(reopened.schemaCompatibility, .ok)
        XCTAssertEqual(try reopened.listPatients().map(\.name), ["Jane Doe"])
    }
}
