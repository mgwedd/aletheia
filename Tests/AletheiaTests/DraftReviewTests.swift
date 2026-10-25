import XCTest
@testable import Aletheia

/// AI-generated progress notes are drafts until a clinician signs them: they
/// are badged, cannot be exported or copied, and signing records the review.
final class DraftReviewTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var patient: Patient!
    private var session: SessionRecord!
    private var audits: [(AuditAction, String?, String?)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = Store(root: root, protector: .passthrough)
        store.onAudit = { [unowned self] action, id, detail in audits.append((action, id, detail?.text)) }
        patient = try store.createPatient(name: "Dana Cole")
        session = try store.createSession(for: patient)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative),
            encoding: .utf8)
    }

    // MARK: Which notes count as AI output, and which may leave

    func testGeneratedAndEditedNotesAreAIOutput() {
        XCTAssertTrue(NoteLifecycle.isAIGenerated(.generated))
        XCTAssertTrue(NoteLifecycle.isAIGenerated(.edited))
        XCTAssertFalse(NoteLifecycle.isAIGenerated(.none))
        XCTAssertFalse(NoteLifecycle.isAIGenerated(.unreadable))
    }

    func testAnUnsignedAINoteMayNotLeave() {
        XCTAssertFalse(NoteLifecycle.allowsLeaving(.draft, aiGenerated: true))
        XCTAssertTrue(NoteLifecycle.allowsLeaving(.draft, aiGenerated: false))
    }

    func testASignedNoteMayLeaveButAnAlteredOneMayNot() {
        let record = NoteLifecycle.sign(text: "x", signer: "a", at: Date(), aiGenerated: true)
        XCTAssertTrue(NoteLifecycle.allowsLeaving(.signed(record), aiGenerated: true))
        XCTAssertFalse(NoteLifecycle.allowsLeaving(.altered(record), aiGenerated: true))
    }

    func testTheWordingIsPlain() {
        XCTAssertEqual(NoteLifecycle.draftBadge, "Draft — needs clinician review")
        XCTAssertEqual(NoteLifecycle.reviewToExport, "Review and sign to export")
    }

    // MARK: Signing an AI note records the review

    func testSigningAnAINoteRecordsAIVerifiedOnce() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        let record = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertTrue(record.aiGenerated)
        XCTAssertEqual(audits.filter { $0.0 == .aiNoteVerified }.count, 1)
        XCTAssertEqual(audits.filter { $0.0 == .noteSigned }.count, 1)
    }

    func testAnEditedAINoteStillRecordsAIVerified() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        try store.saveEditedNote("S: calmer", for: patient, session: session, format: .soap)
        let record = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertTrue(record.aiGenerated)
        XCTAssertEqual(audits.filter { $0.0 == .aiNoteVerified }.count, 1)
    }

    func testAnAINoteStaysAIAfterReopeningAndSigningAgain() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        _ = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        try store.reopenSignedNote(for: patient, session: session, format: .soap)
        _ = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertEqual(audits.filter { $0.0 == .aiNoteVerified }.count, 2, "one per signing, not per app launch")
        XCTAssertEqual(audits.filter { $0.0 == .noteSigned }.count, 2)
    }

    // MARK: Edit-after-sign policy

    func testEditAfterSignRequiresAnExplicitReopenThatIsLogged() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        _ = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertThrowsError(try store.saveEditedNote("S: edited", for: patient, session: session, format: .soap))
        try store.reopenSignedNote(for: patient, session: session, format: .soap)
        XCTAssertEqual(audits.filter { $0.0 == .phiAmended && ($0.2 ?? "").contains("reopened") }.count, 1)
        XCTAssertNoThrow(try store.saveEditedNote("S: edited", for: patient, session: session, format: .soap))
        XCTAssertEqual(try store.noteLifecycle(for: patient, session: session, format: .soap), .draft)
        XCTAssertEqual(store.previousNote(for: patient, session: session, format: .soap), "S: calm")
    }

    // MARK: Exported text carries the draft stamp

    func testStampedTextIsMarkedUnlessSigned() {
        let record = NoteLifecycle.sign(text: "x", signer: "a", at: Date(), aiGenerated: false)
        XCTAssertTrue(NoteLifecycle.stamped("body", status: nil).hasPrefix(NoteLifecycle.exportDraftStamp))
        XCTAssertTrue(NoteLifecycle.stamped("body", status: .draft).hasSuffix("body"))
        XCTAssertTrue(NoteLifecycle.stamped("body", status: .altered(record)).hasPrefix(NoteLifecycle.exportDraftStamp))
        XCTAssertEqual(NoteLifecycle.stamped("body", status: .signed(record)), "body")
    }

    func testSessionMarkdownStampsAnUnsignedSummaryOnly() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        try store.saveSummary("S: calm", for: patient, session: session)
        XCTAssertTrue(store.exportSessionMarkdown(patient: patient, session: session).contains(NoteLifecycle.exportDraftStamp))
        _ = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertFalse(store.exportSessionMarkdown(patient: patient, session: session).contains(NoteLifecycle.exportDraftStamp))
    }

    func testArchiveStampsUnsignedNotesAndLeavesSignedOnesClean() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        let unsigned = try ArchiveLoader.load(store: store, patient: patient, session: session)
        XCTAssertTrue(unsigned.notes[0].text.hasPrefix(NoteLifecycle.exportDraftStamp))
        _ = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        let signed = try ArchiveLoader.load(store: store, patient: patient, session: session)
        XCTAssertFalse(signed.notes[0].text.contains(NoteLifecycle.exportDraftStamp))
        XCTAssertTrue(signed.notes[0].text.contains("calm"))
    }

    // MARK: The view

    func testTheViewGatesExportAndCopyAndShowsTheBadgeFromTheTheme() throws {
        let view = try source("Sources/App/Views/SessionDetailView.swift")
        let model = try source("Sources/App/Services/SessionAI/SessionNoteModel.swift")
        XCTAssertTrue(view.contains("note.mayLeave(message: NoteLifecycle.reviewToExport)"))
        XCTAssertTrue(model.contains("mayLeave(message: NoteLifecycle.reviewToCopy)"))
        XCTAssertTrue(view.contains("Chip(NoteLifecycle.draftBadge, tone: .warn)"))
        XCTAssertFalse(view.contains("Color.orange"))
    }

    func testPsychotherapyNotesStayOutOfTheReviewGate() throws {
        let lifecycle = try source("Sources/App/Services/NoteLifecycle.swift")
        XCTAssertFalse(lifecycle.lowercased().contains("psychotherapy"))
    }
}
