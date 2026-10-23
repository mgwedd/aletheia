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

    func testTheAncestorWalkEndsAtTheRoot() {
        XCTAssertEqual(DataFolderPolicy.ancestors(of: "/Users/clinician/ClinicData").map(\.path),
                       ["/Users/clinician/ClinicData", "/Users/clinician", "/Users", "/"])
        XCTAssertEqual(DataFolderPolicy.ancestors(of: "/").map(\.path), ["/"])

        var visited: [String] = []
        _ = DataFolderPolicy.verdict(for: home.appendingPathComponent("ClinicData"), realHome: home, facts: { url in
            visited.append(url.path)
            return DataFolderPolicy.ResourceFacts()
        })
        XCTAssertEqual(visited, ["/Users/clinician/ClinicData", "/Users/clinician", "/Users", "/", "/Users/clinician/ClinicData"])
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

    func testHomeSyncFoldersOutsideCloudStorageAreRejected() {
        let cases: [(String, String)] = [
            ("Dropbox/records", "Dropbox"),
            ("Dropbox (Personal)/records", "Dropbox"),
            ("OneDrive - Clinic/records", "OneDrive"),
            ("Google Drive/records", "Google Drive"),
            ("Box/records", "Box"),
            ("Box Sync/records", "Box"),
        ]
        for (relative, provider) in cases {
            XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent(relative), realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .thirdPartyCloud(provider), relative)
        }
        for relative in ["Boxes/records", "Dropboxed/records", "Documents/Dropbox/records"] {
            XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent(relative), realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .ok, relative)
        }
    }

    func testSyncVolumeIsRejected() {
        XCTAssertEqual(DataFolderPolicy.verdict(for: URL(fileURLWithPath: "/Volumes/GoogleDrive/My Drive/records"), realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .thirdPartyCloud("Google Drive"))
    }

    func testCloudPathsMatchRegardlessOfCase() {
        XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent("library/mobile documents/records"), realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .iCloudDrive)
        XCTAssertEqual(DataFolderPolicy.verdict(for: home.appendingPathComponent("library/cloudstorage/Dropbox/records"), realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .thirdPartyCloud("Dropbox"))
    }

    func testDropboxMarkerInAncestorIsRejected() {
        let folder = URL(fileURLWithPath: "/Volumes/External/Shared/records")
        let verdict = DataFolderPolicy.verdict(for: folder, realHome: home, resourceValues: { _ in nil }, fileExists: { $0.path == "/Volumes/External/Shared/.dropbox" })
        XCTAssertEqual(verdict, .thirdPartyCloud("Dropbox"))
        XCTAssertEqual(DataFolderPolicy.verdict(for: folder, realHome: home, resourceValues: { _ in nil }, fileExists: { _ in false }), .ok)
    }

    func testMoveSheetStaysHiddenWhileAppIsLocked() {
        XCTAssertFalse(DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: true))
        XCTAssertTrue(DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: false))
        XCTAssertFalse(DataFolderPolicy.presentsMoveSheet(requested: false, appLocked: false))
    }
}
