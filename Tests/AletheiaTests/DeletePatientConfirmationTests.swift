import XCTest
@testable import Aletheia

final class DeletePatientConfirmationTests: XCTestCase {
    func testCopyWarnsAboutRetentionAndPermanence() {
        let c = DeletePatientConfirmation(patientName: "Sam", sessionDates: [])
        let text = c.paragraphs.joined(separator: " ")
        XCTAssertTrue(text.contains("required to be kept"))
        XCTAssertTrue(text.contains("after the last visit"))
        XCTAssertTrue(text.contains("permanently delete"))
        XCTAssertTrue(text.contains("cannot be undone"))
        XCTAssertTrue(text.contains("Cancel keeps everything"))
    }

    func testCopyNamesNoSpecificStatute() {
        let text = DeletePatientConfirmation(patientName: "Sam", sessionDates: []).paragraphs.joined(separator: " ")
        XCTAssertNil(text.range(of: "§"))
        XCTAssertNil(text.range(of: "Code", options: .caseInsensitive))
    }

    func testShowsLatestSessionDate() {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_750_000_000)
        let c = DeletePatientConfirmation(patientName: "Sam", sessionDates: [early, late, early])
        XCTAssertEqual(c.lastSessionDate, late)
        XCTAssertTrue(c.lastSessionLine.contains(late.formatted(date: .long, time: .omitted)))
        XCTAssertTrue(c.paragraphs.contains(c.lastSessionLine))
    }

    func testNoSessionsSaysSo() {
        let c = DeletePatientConfirmation(patientName: "Sam", sessionDates: [])
        XCTAssertNil(c.lastSessionDate)
        XCTAssertEqual(c.lastSessionLine, "No sessions are recorded for this patient.")
    }

    func testTitleNamesPatient() {
        XCTAssertEqual(DeletePatientConfirmation(patientName: "Sam", sessionDates: []).title, "Delete Sam?")
    }

    /// Cancel dismisses the sheet without calling the delete closure, and the
    /// delete button is only wired to `onDelete`.
    func testSheetOnlyDeletesThroughDeleteButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/PatientProfileEditor.swift"), encoding: .utf8)
        let sheet = try XCTUnwrap(src.range(of: "struct DeletePatientConfirmationView"))
        let body = String(src[sheet.lowerBound...])
        XCTAssertEqual(body.components(separatedBy: "onDelete()").count - 1, 1)
        let cancel = try XCTUnwrap(body.range(of: "Button(\"Cancel\", role: .cancel) {"))
        let afterCancel = String(body[cancel.upperBound...].prefix(80))
        XCTAssertTrue(afterCancel.contains("dismiss()"))
        XCTAssertFalse(afterCancel.contains("onDelete"))
        XCTAssertTrue(body.contains(".disabled(!matches)"))
    }
}
