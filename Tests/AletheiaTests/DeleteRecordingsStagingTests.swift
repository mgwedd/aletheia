import CryptoKit
import XCTest
@testable import Aletheia

/// Deleting a session's recordings also clears its temporary audio folder, and
/// says so when that folder can't be removed.
final class DeleteRecordingsStagingTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private struct EncryptedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    private final class MemoryDeviceKeys: DeviceKeyStoring {
        private var keys: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { keys[id] = key }
        func load(for id: String) -> SymmetricKey? { keys[id] }
        func delete(for id: String) { keys[id] = nil }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "DeleteRecordingsStagingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private var root: URL!
    private var originalRoot: URL?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalRoot = AppSettings.shared.dataRootURL
    }

    override func tearDownWithError() throws {
        AppSettings.shared.dataRootURL = originalRoot
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> (Store, Patient, SessionRecord) {
        AppSettings.shared.dataRootURL = root
        let r = root!
        let encryption = EncryptionManager(
            dataRootProvider: { r }, deviceKeys: MemoryDeviceKeys(), defaults: isolatedDefaults())
        let model = AppModel(settings: AppSettings.shared, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
        model.diskProbe = EncryptedDisk()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        return (try XCTUnwrap(model.store), patient, session)
    }

    func testDeleteRemovesTheTemporaryAudioFolder() throws {
        let (store, patient, session) = try makeStore()
        let staging = Store.stagingDir(for: session.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staging.appendingPathComponent("mic.caf"))

        try store.deleteRecordings(for: patient, session: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testDeleteReportsATemporaryAudioFolderThatCannotBeRemoved() throws {
        let (store, patient, session) = try makeStore()
        let staging = Store.stagingDir(for: session.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staging.appendingPathComponent("mic.caf"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try? FileManager.default.removeItem(at: staging)
        }

        XCTAssertThrowsError(try store.deleteRecordings(for: patient, session: session)) {
            guard case .recordingNotDeleted? = $0 as? StoreError else { return XCTFail("got \($0)") }
        }
    }
}
