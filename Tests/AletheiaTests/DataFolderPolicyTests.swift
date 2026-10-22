import XCTest
@testable import Aletheia

final class DataFolderPolicyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/clinician")

    func testCloudStoragePathsAreRejected() {
        XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent("Library/Mobile Documents/records"), realHome: home, resourceValues: { _ in nil }), .iCloudDrive)
        XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent("Library/CloudStorage/Dropbox/records"), realHome: home, resourceValues: { _ in nil }), .thirdPartyCloud("Dropbox"))
    }

    func testLocalPathsAreAccepted() {
        XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent("ClinicData"), realHome: home, resourceValues: { _ in nil }), .ok)
        XCTAssertEqual(DataFolderPolicy.verdict(for: URL(fileURLWithPath: "/Users/clinician/Library/Application Support/Aletheia/Data"), realHome: home, resourceValues: { _ in nil }), .ok)
    }

    func testUbiquitousAncestorIsRejected() {
        let folder = home.appendingPathComponent("Documents/ClinicData")
        let verdict = DataFolderPolicy.verdict(for: folder, realHome: home, facts: { url in
            DataFolderPolicy.ResourceFacts(ubiquitous: url.lastPathComponent == "Documents")
        })
        XCTAssertEqual(verdict, .iCloudDesktopDocuments)
    }

    func testNonlocalAndUnencryptedRemovableVolumesAreRejected() {
        let folder = URL(fileURLWithPath: "/Volumes/Records")
        XCTAssertEqual(DataFolderPolicy.verdict(for: folder, realHome: home, facts: { _ in
            DataFolderPolicy.ResourceFacts(localVolume: false)
        }), .networkVolume)
        XCTAssertEqual(DataFolderPolicy.verdict(for: folder, realHome: home, facts: { _ in
            DataFolderPolicy.ResourceFacts(localVolume: true, removableVolume: true, encryptedVolume: false)
        }), .removableUnencrypted)
    }

    func testSymlinkIntoCloudStorageIsRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cloud = base.appendingPathComponent("Library/Mobile Documents/records")
        let link = base.appendingPathComponent("ClinicData")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cloud)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(DataFolderPolicy.verdict(for: link, realHome: base, resourceValues: { _ in nil }), .iCloudDrive)
    }

    func testPickerDoesNotRecommendCloudStorage() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/App/Services/FolderPicker.swift"))
        XCTAssertFalse(source.contains("CloudDocs"))
        XCTAssertFalse(source.contains("iCloud Drive"))
    }
}
