import XCTest
@testable import Aletheia

final class TherapistInputTests: XCTestCase {
    func testLimitIsAboutOneHundredPages() {
        XCTAssertEqual(TherapistInput.pageLimit, 100)
        XCTAssertEqual(TherapistInput.characterLimit, 300_000)
    }

    func testTextWithinRoomGoesInWhole() {
        let fitted = TherapistInput.fit("  Prefers mornings.  ", room: 100, query: "mornings")
        XCTAssertEqual(fitted, TherapistInput.Fitted(text: "Prefers mornings.", excerpted: false))
    }

    func testTextOverRoomIsExcerptedNotCut() {
        let text = (1...500).map { "Paragraph \($0) on routine matters." }.joined(separator: "\n")
            + "\nThe medication change to sertraline in May."
        let fitted = TherapistInput.fit(text, room: 1_000, query: "sertraline")
        XCTAssertTrue(fitted.excerpted)
        XCTAssertLessThanOrEqual(fitted.text.count, 1_000)
        XCTAssertTrue(fitted.text.contains("sertraline"))
        XCTAssertTrue(fitted.text.contains("too long to include whole"))
    }

    func testNoMatchFallsBackToTheOpening() {
        let text = (1...500).map { "Paragraph \($0)." }.joined(separator: "\n")
        let fitted = TherapistInput.fit(text, room: 400, query: "zebra")
        XCTAssertTrue(fitted.excerpted)
        XCTAssertTrue(fitted.text.contains("Paragraph 1."))
        XCTAssertLessThanOrEqual(fitted.text.count, 400)
    }

    func testOverTheLimitIsAnErrorNamingTheField() {
        let huge = String(repeating: "x", count: TherapistInput.characterLimit + 1)
        XCTAssertThrowsError(try TherapistFields(
            notes: "", comments: [], background: huge, query: "", budget: ContextBudget(tokens: 8_192))) { error in
            XCTAssertEqual(error as? TherapistInput.TooLong, TherapistInput.TooLong(field: .background))
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("The patient background is too long"))
            XCTAssertTrue(message.contains("100 pages"))
        }
        XCTAssertThrowsError(try TherapistInput.check([("ok", .notes), (huge, .question)])) { error in
            XCTAssertEqual(error as? TherapistInput.TooLong, TherapistInput.TooLong(field: .question))
        }
        XCTAssertNoThrow(try TherapistInput.check([(String(repeating: "x", count: TherapistInput.characterLimit), .notes)]))
    }

    func testCoverageNoteListsFields() {
        XCTAssertNil(TherapistInput.coverageNote([]))
        XCTAssertEqual(
            TherapistInput.coverageNote([.notes, .background]),
            "Only the parts of the session notes and the patient background that match were read: they are too long to send whole.")
    }

    func testPatientChatFailsBeforeAnyModelCallWhenTheBackgroundIsTooLong() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        var patient = try store.createPatient(name: "Dana Cole")
        patient.clinicalHistory = String(repeating: "history ", count: TherapistInput.characterLimit / 8 + 10)
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "sleep", characterBudget: 40_000)
        XCTAssertEqual(context.inputError, TherapistInput.TooLong(field: .background))
        XCTAssertTrue(context.text.isEmpty)
    }

    func testPatientChatExcerptsALongBackgroundAndSaysSo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        var patient = try store.createPatient(name: "Dana Cole")
        patient.clinicalHistory = (1...2_000).map { "Visit \($0): routine." }.joined(separator: "\n")
            + "\nSleep has been poor since the move."
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "sleep", characterBudget: 8_000)
        XCTAssertNil(context.inputError)
        XCTAssertEqual(context.coverage.excerptedFields, [.background])
        XCTAssertTrue(context.text.contains("Sleep has been poor"))
        XCTAssertFalse(context.text.contains("Visit 1500: routine."))
    }
}
