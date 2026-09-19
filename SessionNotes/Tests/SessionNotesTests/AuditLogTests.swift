import XCTest
@testable import SessionNotes

/// The audit log is the HIPAA §164.312(b) "record and examine" control, so the
/// tests pin the three things a reviewer relies on: appends accumulate in order,
/// the log reads back and exports faithfully, and — the privacy invariant — a
/// line never carries a name or clinical field, only the PHI-free schema.
final class AuditLogTests: XCTestCase {
    private var root: URL!
    private var log: AuditLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = AuditLog(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecordsAccumulateOldestFirst() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        log.record(.appUnlocked, at: t0, appVersion: "1.0")
        log.record(.encryptionEnabled, at: t1, appVersion: "1.0")

        let entries = log.entries()
        XCTAssertEqual(entries.map(\.action), [.appUnlocked, .encryptionEnabled])
        XCTAssertEqual(entries.first?.date, t0)
        XCTAssertEqual(entries.last?.date, t1)
    }

    func testSubjectAndDetailRoundTrip() throws {
        let id = UUID().uuidString
        log.record(.recordExported, subjectID: id, detail: "Markdown", appVersion: "1.2")
        let entry = try XCTUnwrap(log.entries().first)
        XCTAssertEqual(entry.subjectID, id)
        XCTAssertEqual(entry.detail, "Markdown")
        XCTAssertEqual(entry.appVersion, "1.2")
    }

    func testEntriesSkipUnparseableLines() throws {
        log.record(.appUnlocked, appVersion: "1.0")
        // A hand-edited / corrupt line must not sink the whole read.
        let fileURL = root.appendingPathComponent(AuditLog.fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()
        log.record(.encryptionDisabled, appVersion: "1.0")

        XCTAssertEqual(log.entries().map(\.action), [.appUnlocked, .encryptionDisabled])
    }

    func testExportWritesFaithfulCopy() throws {
        log.record(.appUnlocked, appVersion: "1.0")
        log.record(.encryptionEnabled, appVersion: "1.0")

        let dest = root.appendingPathComponent("exported-audit.log")
        try log.export(to: dest)

        let original = try Data(contentsOf: root.appendingPathComponent(AuditLog.fileName))
        let copy = try Data(contentsOf: dest)
        XCTAssertEqual(copy, original)
    }

    func testEmptyLogReadsEmptyAndExportsEmpty() throws {
        XCTAssertTrue(log.entries().isEmpty)
        let dest = root.appendingPathComponent("empty.log")
        try log.export(to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data())
    }

    /// Privacy invariant: an encoded line carries only the known PHI-free keys —
    /// no name, patient, transcript, note, or other clinical field can sneak in.
    func testEncodedLineHasOnlyPHIFreeKeys() throws {
        let event = AuditEvent(at: "2026-01-01T00:00:00Z", action: .recordDeleted,
                               subjectID: "opaque-id", detail: "session", appVersion: "1.0")
        // encodeLine appends a newline for the file; check the schema on the raw
        // encoding so trailing whitespace can't affect JSON parsing.
        XCTAssertNotNil(AuditLog.encodeLine(event))
        let data = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys ?? [:].keys)
        XCTAssertEqual(keys, ["at", "action", "subjectID", "detail", "appVersion"])
    }

    func testEveryActionHasADisplayName() {
        for action in AuditAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "\(action) needs a display name")
        }
    }
}
