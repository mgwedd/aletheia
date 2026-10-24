import XCTest
@testable import Aletheia

/// The activity log's caption must say only what the app really records.
final class AuditLogCopyTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
    }

    /// Every action passed to `record(` / `recordAudit(` anywhere in the app.
    private func actionsRecordedInSource() throws -> Set<String> {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let regex = try NSRegularExpression(pattern: #"(?:recordAudit|\.record)\(\s*\.(\w+)"#)
        var found = Set<String>()
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
            }
        }
        return found
    }

    func testCaptionedActionsAreExactlyTheWiredOnes() throws {
        let wired = try actionsRecordedInSource()
        XCTAssertFalse(wired.isEmpty)
        let captioned = Set(AuditLogCopy.recordedActions.map(\.rawValue))
        XCTAssertEqual(captioned, wired, "Update AuditLogCopy.recorded when an action is wired or unwired")
    }

    func testCaptionNamesBackupsAndDeletionsAsRecorded() {
        let caption = AuditLogCopy.caption
        XCTAssertTrue(caption.contains("deletions"))
        XCTAssertTrue(caption.contains("backups"))
        XCTAssertTrue(caption.contains("Viewing records is not recorded yet"))
        XCTAssertFalse(caption.localizedCaseInsensitiveContains("backups are not recorded"))
        XCTAssertTrue(caption.contains("§164.312(b)"), "keeps the audit-control note")
        XCTAssertFalse(AuditLogCopy.notRecordedActions.contains(.backupRun))
        XCTAssertFalse(AuditLogCopy.notRecordedActions.contains(.recordDeleted))
    }

    func testPagingWalksNewestToOldest() {
        var paging = AuditLogPaging(pageSize: 10, total: 25)
        XCTAssertEqual(paging.pageCount, 3)
        XCTAssertEqual(paging.range, 0..<10)
        XCTAssertFalse(paging.hasNewer)
        XCTAssertTrue(paging.hasOlder)
        paging.page = 2
        XCTAssertEqual(paging.range, 20..<25)
        XCTAssertFalse(paging.hasOlder)
        XCTAssertEqual(paging.summary, "Showing 21–25 of 25 entries, newest first.")
        paging.page = 99
        XCTAssertEqual(paging.currentPage, 2)
    }

    func testPagingEmptyAndExactFit() {
        XCTAssertEqual(AuditLogPaging(total: 0).range, 0..<0)
        XCTAssertEqual(AuditLogPaging(total: 0).summary, "")
        XCTAssertEqual(AuditLogPaging(pageSize: 5, total: 10).pageCount, 2)
    }

    func testDetailLineShowsNoteActorAndShortRecordID() {
        let id = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        let entry = AuditEvent(at: "2026-01-01T00:00:00Z", actor: "sam:501", action: .recordExported,
                               subjectID: id, detail: "Session, PDF")
        XCTAssertEqual(AuditLogSection.detailLine(entry), "Session, PDF · by sam:501 · record ABCDEF12")
        let bare = AuditEvent(at: "2026-01-01T00:00:00Z", actor: AuditLog.unknownActor, action: .appLocked)
        XCTAssertNil(AuditLogSection.detailLine(bare))
    }
}
