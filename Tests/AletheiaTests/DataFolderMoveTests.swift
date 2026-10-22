import XCTest
@testable import Aletheia

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
}
