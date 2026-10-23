import CryptoKit
import XCTest
@testable import Aletheia

private final class MemoryDeviceKeys: DeviceKeyStoring {
    var storage: [String: SymmetricKey] = [:]
    func save(_ key: SymmetricKey, for id: String) throws { storage[id] = key }
    func load(for id: String) -> SymmetricKey? { storage[id] }
    func delete(for id: String) { storage[id] = nil }
}

private struct NoopSpotlight: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

final class DataFolderMoveTests: XCTestCase {
    func testCopyVerifiesAndRebindsWithoutDeletingSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("patient"), withIntermediateDirectories: true)
        try Data("patient".utf8).write(to: source.appendingPathComponent("patient/patient.json"))
        defer { try? FileManager.default.removeItem(at: base) }
        var rebound: URL?
        try DataFolderMove.copyAndRebind(source: source, destination: destination) { rebound = $0 }
        XCTAssertEqual(rebound, destination)
        XCTAssertTrue(try DataFolderMove.verifyCopy(source, destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("patient/patient.json").path))
    }

    func testFailedVerificationLeavesBindingAndSourceUnchanged() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("patient.json"))
        defer { try? FileManager.default.removeItem(at: base) }
        var didRebind = false
        XCTAssertThrowsError(try DataFolderMove.copyAndRebind(source: source, destination: destination, verify: { _, _ in false }, rebind: { _ in didRebind = true }))
        XCTAssertFalse(didRebind)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("patient.json")), "original")
    }

    func testOverlappingFoldersAreRejectedBeforeCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var rebound = false
        XCTAssertThrowsError(try DataFolderMove.copyAndRebind(source: source, destination: source.appendingPathComponent("Data"), rebind: { _ in rebound = true }))
        XCTAssertFalse(rebound)
    }

    func testMoveIntoChosenFolderStagesInsideIt() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let chosen = base.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Data("patient".utf8).write(to: source.appendingPathComponent("patient.json"))
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = DataFolderMove.destination(inChosenFolder: chosen)
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, chosen.standardizedFileURL)
        var stagedInChosen = false
        try DataFolderMove.copyAndRebind(source: source, destination: destination, verify: { original, staged in
            stagedInChosen = staged.deletingLastPathComponent().standardizedFileURL == chosen.standardizedFileURL
            return try DataFolderMove.verifyCopy(original, staged)
        }, rebind: { _ in })
        XCTAssertTrue(stagedInChosen)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted(), ["chosen", "source"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("patient.json")), "patient")
    }

    func testMovedEncryptedFolderUnlocksWithRememberedKey() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let previousRoot = settings.dataRootURL
        defer {
            settings.dataRootURL = previousRoot
            try? FileManager.default.removeItem(at: base)
        }
        settings.dataRootURL = source
        let encryption = EncryptionManager(dataRootProvider: { settings.dataRootURL }, deviceKeys: MemoryDeviceKeys())
        let appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlight())
        _ = try encryption.enable(passphrase: "correct horse battery", iterations: 100_000)
        try encryption.rememberOnDevice()
        XCTAssertTrue(encryption.isUnlocked)

        try DataFolderMove.copyAndRebind(source: source, destination: destination) { settings.dataRootURL = $0 }
        appModel.dataFolderMoved()

        XCTAssertEqual(encryption.state, .unlocked, "a key remembered on this Mac unlocks the moved copy")
        XCTAssertNotNil(appModel.store)
    }
}
