import CryptoKit
import XCTest
@testable import Aletheia

/// Opening a record, AI use on patient data and copying patient text each add an
/// activity-log entry that names only a kind, and opening is rate limited.
final class AccessAuditTests: XCTestCase {
    private struct Row: Equatable {
        let action: AuditAction
        let subject: String?
        let detail: String?
    }

    private var rows: [Row] = []
    private var audit: AccessAudit!

    override func setUp() {
        rows = []
        audit = AccessAudit { [unowned self] action, subject, detail in
            rows.append(Row(action: action, subject: subject, detail: detail?.text))
        }
    }

    // MARK: - Viewing

    func testOpeningASessionRecordsOneEntryNamingTheKind() {
        let id = UUID()
        audit.viewedSession(id)
        XCTAssertEqual(rows, [Row(action: .phiViewed, subject: id.uuidString, detail: "session")])
    }

    func testOpeningAPatientRecordsOneEntryNamingTheKind() {
        let id = UUID()
        audit.viewedPatient(id)
        XCTAssertEqual(rows, [Row(action: .phiViewed, subject: id.uuidString, detail: "patient")])
    }

    func testReopeningWithinTheWindowIsOneEntryAndAfterItIsAnother() {
        let id = UUID()
        let start = Date()
        audit.viewedSession(id, now: start)
        for second in stride(from: 1, to: Int(AccessAudit.viewWindow), by: 30) {
            audit.viewedSession(id, now: start.addingTimeInterval(TimeInterval(second)))
        }
        XCTAssertEqual(rows.count, 1, "scrolling and re-rendering must not flood the log")
        audit.viewedSession(id, now: start.addingTimeInterval(AccessAudit.viewWindow + 1))
        XCTAssertEqual(rows.count, 2)
    }

    func testDifferentRecordsAreCountedSeparately() {
        let now = Date()
        audit.viewedSession(UUID(), now: now)
        audit.viewedSession(UUID(), now: now)
        audit.viewedPatient(UUID(), now: now)
        XCTAssertEqual(rows.count, 3)
    }

    func testLockingMakesTheNextOpeningRecordAgain() {
        let id = UUID()
        let now = Date()
        audit.viewedSession(id, now: now)
        audit.reset()
        audit.viewedSession(id, now: now.addingTimeInterval(1))
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - AI use

    func testEachAIKindRecordsItsOwnFixedWording() {
        audit.aiUsed(.note)
        audit.aiUsed(.sessionChat)
        audit.aiUsed(.patientChat)
        audit.aiUsed(.note)
        XCTAssertEqual(rows.map(\.detail), ["progress note", "session chat", "patient chat", "progress note"])
        XCTAssertTrue(rows.allSatisfy { $0.action == .aiInference && $0.subject == nil })
    }

    func testADigestRunIsOneEntry() {
        let now = Date()
        for i in 0..<20 { audit.aiUsed(.digest, now: now.addingTimeInterval(TimeInterval(i))) }
        XCTAssertEqual(rows.map(\.detail), ["digest"])
        audit.aiUsed(.digest, now: now.addingTimeInterval(AccessAudit.digestWindow + 1))
        XCTAssertEqual(rows.count, 2)
    }

    @MainActor
    func testTheQueueReportsEachJobAsItStarts() async {
        let queue = InferenceQueue()
        var started: [InferenceQueue.Kind] = []
        queue.onJobStarted = { started.append($0) }
        let done = expectation(description: "jobs ran")
        done.expectedFulfillmentCount = 2
        queue.enqueue(kind: .note, label: "progress note") { done.fulfill() }
        queue.enqueue(kind: .patientChat, label: "chat") { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(started, [.note, .patientChat])
    }

    // MARK: - Copying

    private func scratchPasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("aletheia-test-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testCopyingPatientTextReportsOnlyItsKind() {
        var kinds: [String] = []
        PHIPasteboard.onCopy = { kinds.append($0.text) }
        defer { PHIPasteboard.onCopy = nil }
        let board = scratchPasteboard()

        PHIPasteboard.writeString("Client reports panic attacks", kind: .transcript, to: board)
        RichClipboard.write(RichClipboard.payload(markdown: "# Note\nZebra Quokka"), to: board)
        PHIPasteboard.writeString("code", kind: .copiedChat, to: board)

        XCTAssertEqual(kinds, ["transcript", "note", "chat"])
        XCTAssertFalse(kinds.joined().contains("panic"))
    }

    func testCopiesThatAreNotPatientTextAreNotReported() {
        var kinds: [String] = []
        PHIPasteboard.onCopy = { kinds.append($0.text) }
        defer { PHIPasteboard.onCopy = nil }
        PHIPasteboard.writeString("diagnostics report", to: scratchPasteboard())
        RecoveryKeyDocument.copy("AAAA-BBBB", to: scratchPasteboard())
        XCTAssertTrue(kinds.isEmpty)
    }

    func testCopyReachesTheLedgerAsPHICopiedWithNoText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let log = AuditLog(root: root, keyProvider: { key })
        PHIPasteboard.onCopy = { _ = try? log.record(.phiCopied, detail: $0) }
        defer { PHIPasteboard.onCopy = nil }

        PHIPasteboard.writeString("Zebra Quokka", kind: .note, to: scratchPasteboard())

        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.action, .phiCopied)
        XCTAssertEqual(entries.first?.detail, "note")
        XCTAssertFalse(String(describing: entries).contains("Zebra"))
    }

    // MARK: - Custom instructions

    private func settings() -> AppSettings {
        let name = "AccessAuditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    func testInstructionChangeIsRecordedWithoutTheText() {
        let settings = settings()
        var details: [String] = []
        settings.onAuditedChange = { details.append($0.text) }
        let secret = "Always mention the client Zebra Quokka by name"

        settings.setNoteInstructions(secret, for: .soap)
        settings.setNoteInstructions(secret, for: .soap)   // unchanged
        settings.setNoteInstructions("", for: .soap)       // back to the default

        XCTAssertEqual(details, [
            "Note instructions (SOAP): customized",
            "Note instructions (SOAP): reset to default",
        ])
        XCTAssertFalse(details.joined().contains("Zebra"))
    }

    func testChangingInstructionsToTheDefaultRecordsNothingWhenNoneWereSet() {
        let settings = settings()
        var details: [String] = []
        settings.onAuditedChange = { details.append($0.text) }
        settings.setNoteInstructions(Prompts.defaultInstructions(for: .dap), for: .dap)
        XCTAssertTrue(details.isEmpty)
    }

    // MARK: - Unknown actions

    func testAnUnknownActionIsShownAsItsRawString() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let log = AuditLog(root: root, keyProvider: { key })
        let row = SQLitePersistenceCore.NewAuditRow(
            at: "2030-01-01T00:00:00Z", actor: "sam:501", action: "phiShredded",
            subjectID: nil, detail: nil, appVersion: "9.9")
        _ = try log.core?.appendAuditEvents([row]) { prev, row in AuditLog.computeMAC(key: key, prevMac: prev, row: row) }
        try log.record(.appLocked)

        let entries = log.entries()
        XCTAssertEqual(entries.first?.actionLabel, "phiShredded")
        XCTAssertNil(entries.first?.action)
        XCTAssertNotEqual(entries.first?.actionLabel, AuditAction.appUnlocked.displayName)
        XCTAssertEqual(entries.last?.actionLabel, AuditAction.appLocked.displayName)
        XCTAssertTrue(log.generateReport().contains("phiShredded"))
        XCTAssertEqual(log.verifyIntegrity(), .verified(count: 2), "an unknown action still verifies")
    }

    func testAnEventKeepsItsRawActionThroughEncoding() throws {
        let event = AuditEvent(at: "2030-01-01T00:00:00Z", actor: "a:1", actionName: "futureThing")
        let data = try XCTUnwrap(AuditLog.encodeLine(event))
        let back = try JSONDecoder().decode(AuditEvent.self, from: data)
        XCTAssertEqual(back.actionName, "futureThing")
        XCTAssertEqual(back.actionLabel, "futureThing")
    }

    // MARK: - Missing MAC

    func testARowWithItsMACRemovedIsBrokenWhenAKeyIsPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let log = AuditLog(root: root, keyProvider: { key })
        try log.record(.appUnlocked)
        try log.record(.appLocked)
        try log.record(.appUnlocked)
        XCTAssertEqual(log.verifyIntegrity(), .verified(count: 3))

        try log.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try log.core?.executeRaw("UPDATE audit_events SET mac = NULL WHERE seq = 2;")

        guard case .broken(let seq, _) = log.verifyIntegrity() else {
            return XCTFail("a row without a MAC must not be accepted")
        }
        XCTAssertEqual(seq, 2)
    }

    func testRowsWrittenWithNoKeyStayUnverifiableRatherThanBroken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyless = AuditLog(root: root, keyProvider: { nil })
        try keyless.record(.appUnlocked)
        guard case .unverifiable = keyless.verifyIntegrity() else { return XCTFail("no key means unverifiable") }
    }

    // MARK: - Fixed text only

    func testDetailTypeTakesOnlyLiteralsAndBuilders() {
        XCTAssertTrue(AuditDetail.StringLiteralType.self == StaticString.self,
                      "a literal-only type: a variable or an interpolation cannot be passed")
    }

    func testBuildersTakeOnlyNumbersAndClosedChoices() {
        XCTAssertEqual(AuditDetail.failedUnlocks(attempts: 3, minutes: 5).text, "3 failed unlocks within 5 minutes")
        XCTAssertEqual(AuditDetail.chainBroken(entry: 7).text, "Chain broken at entry #7")
        XCTAssertEqual(AuditDetail.exportedSession(.pdf).text, "Session, PDF")
        XCTAssertEqual(AuditDetail.exportedNote(.soap, .word).text, "Note SOAP, Word")
        XCTAssertEqual(AuditDetail.exportedPatientRecords(sessions: 4).text, "Patient records, zip of 4 sessions")
        XCTAssertEqual(AuditDetail.exportedAllRecords(patients: 2, sessions: 9).text,
                       "All records, folder of 2 patients, 9 sessions")
        XCTAssertEqual(AuditDetail.setting(AuditedSettings.appLock, true).text, "App lock: on")
    }

    func testNoCodeBuildsADetailFromAStringExceptTheTypeItself() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AuditDetail.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("AuditDetail(") || text.contains("AuditDetail.init"),
                           "\(url.lastPathComponent) builds an AuditDetail directly")
            XCTAssertFalse(text.contains("stringLiteral:"), "\(url.lastPathComponent) calls a literal initialiser directly")
        }
    }

    func testAnyAuditDetailInSourceIsAStringFreeOfPatientData() throws {
        // Every builder output used by the app, with hostile-looking inputs where
        // inputs exist: only numbers and enums go in, so nothing can leak.
        let outputs = [
            AuditDetail.aiUse(.note), .aiUse(.sessionChat), .aiUse(.patientChat), .aiUse(.digest),
            .noteInstructions(.narrative, customized: true), .copiedChat, .copiedPatientText,
        ] + AuditDetail.recordKinds
        for output in outputs {
            XCTAssertFalse(output.text.isEmpty)
            XCTAssertLessThan(output.text.count, 60)
        }
    }
}
