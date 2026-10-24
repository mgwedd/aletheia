import AppKit
import XCTest
@testable import Aletheia

final class RecoveryKeyDocumentTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryKeyDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testMarkdownListsEveryWordNumberedInOrder() {
        let key = RecoveryKey.generate()
        let markdown = RecoveryKeyDocument.markdown(key: key, folderName: "Practice", created: Date(), replacesPrevious: false)
        let listed = markdown.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0].hasSuffix("."), Int(parts[0].dropLast()) != nil else { return nil }
            return String(parts[1])
        }
        XCTAssertEqual(listed, RecoveryKey.words(from: key))
        XCTAssertEqual(try RecoveryKey.normalizeAndValidate(listed.joined(separator: " ")), key)
        XCTAssertTrue(markdown.contains("Practice"))
        XCTAssertFalse(markdown.contains("replaces any previously issued"))
    }

    func testMarkdownMentionsReplacementOnlyWhenReplacing() {
        let markdown = RecoveryKeyDocument.markdown(
            key: RecoveryKey.generate(), folderName: "Practice", created: Date(), replacesPrevious: true
        )
        XCTAssertTrue(markdown.contains("replaces any previously issued recovery key"))
    }

    func testDestinationInsideDataFolderIsDetected() {
        let root = tempRoot.appendingPathComponent("Data", isDirectory: true)
        XCTAssertTrue(RecoveryKeyDocument.isInsideDataFolder(root.appendingPathComponent("key.pdf"), dataRoot: root))
        XCTAssertTrue(RecoveryKeyDocument.isInsideDataFolder(
            root.appendingPathComponent("Sessions/a/key.pdf"), dataRoot: root
        ))
        XCTAssertTrue(RecoveryKeyDocument.isInsideDataFolder(
            root.appendingPathComponent("Sessions/../key.pdf"), dataRoot: root
        ))
        // A sibling whose name merely starts with the folder's name is outside.
        XCTAssertFalse(RecoveryKeyDocument.isInsideDataFolder(
            tempRoot.appendingPathComponent("Data2/key.pdf"), dataRoot: root
        ))
        XCTAssertFalse(RecoveryKeyDocument.isInsideDataFolder(tempRoot.appendingPathComponent("key.pdf"), dataRoot: root))
        XCTAssertFalse(RecoveryKeyDocument.isInsideDataFolder(tempRoot.appendingPathComponent("key.pdf"), dataRoot: nil))
    }

    func testDestinationThroughSymlinkIntoDataFolderIsDetected() throws {
        let root = tempRoot.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertTrue(RecoveryKeyDocument.isInsideDataFolder(link.appendingPathComponent("key.pdf"), dataRoot: root))
    }

    func testWriteRefusesDataFolderAndWritesElsewhere() throws {
        let root = tempRoot.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("pdf".utf8)

        let inside = root.appendingPathComponent("key.pdf")
        XCTAssertEqual(
            RecoveryKeyDocument.write(data, to: inside, dataRoot: root),
            .failed(RecoveryKeyDocument.insideDataFolderMessage)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))

        let outside = tempRoot.appendingPathComponent("key.pdf")
        XCTAssertEqual(RecoveryKeyDocument.write(data, to: outside, dataRoot: root, verdict: { _ in .ok }), .saved(outside))
        XCTAssertEqual(try Data(contentsOf: outside), data)
    }

    func testWriteRefusesSyncedDestination() {
        let data = Data("pdf".utf8)
        let destination = tempRoot.appendingPathComponent("key.pdf")
        let refused: [DataFolderPolicy.Verdict] = [
            .iCloudDrive, .iCloudDesktopDocuments, .thirdPartyCloud("Dropbox"), .networkVolume, .removableUnencrypted
        ]
        for placement in refused {
            let outcome = RecoveryKeyDocument.write(data, to: destination, dataRoot: nil, verdict: { _ in placement })
            XCTAssertEqual(outcome, .failed("The recovery key can't be saved here. \(placement.explanation)"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testWriteClassifiesTheFolderTheFileGoesIn() {
        let destination = tempRoot.appendingPathComponent("Sub/key.pdf")
        var asked: URL?
        _ = RecoveryKeyDocument.write(Data(), to: destination, dataRoot: nil, verdict: { asked = $0; return .iCloudDrive })
        XCTAssertEqual(asked?.path, tempRoot.appendingPathComponent("Sub").standardizedFileURL.path)
    }

    func testWriteRefusesICloudFolderUnderRealPolicy() {
        let home = tempRoot.appendingPathComponent("Home", isDirectory: true)
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/key.pdf")
        let outcome = RecoveryKeyDocument.write(Data(), to: iCloud, dataRoot: nil, verdict: {
            DataFolderPolicy.verdict(for: $0, realHome: home, facts: { _ in nil })
        })
        XCTAssertEqual(outcome, .failed("The recovery key can't be saved here. \(DataFolderPolicy.Verdict.iCloudDrive.explanation)"))
    }

    func testWriteAllowsLocalDestination() throws {
        let data = Data("pdf".utf8)
        let destination = tempRoot.appendingPathComponent("key.pdf")
        XCTAssertEqual(
            RecoveryKeyDocument.write(data, to: destination, dataRoot: nil, verdict: { _ in .ok }),
            .saved(destination)
        )
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testCopyMarksPasteboardConcealedAndTransient() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aletheia-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let key = RecoveryKey.generate()
        RecoveryKeyDocument.copy(key, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), key)
        let types = try XCTUnwrap(pasteboard.pasteboardItems?.first?.types)
        XCTAssertTrue(types.contains(PHIPasteboard.concealed))
        XCTAssertTrue(types.contains(PHIPasteboard.transient))
    }
}
