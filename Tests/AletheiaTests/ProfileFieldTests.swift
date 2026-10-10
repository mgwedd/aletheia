import AppKit
import XCTest
@testable import Aletheia

final class ProfileFieldTests: XCTestCase {
    /// The profile card passes the row's label to pick the editor box, so a
    /// renamed label would silently focus the name field. Tie them together.
    func testEveryProfileRowLabelMapsToItsBox() {
        var patient = Patient(name: "Test Patient", slug: "test-patient")
        patient.clinicalHistory = "History"
        patient.notes = "Note"
        patient.medications = [Medication(name: "Lamotrigine", dose: "100 mg")]
        let rows = patient.profileRows(includeMedications: true)
        let mapped = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, ProfileField(rowLabel: $0.label)) })
        XCTAssertEqual(mapped["Clinical history"], .clinicalHistory)
        XCTAssertEqual(mapped["Medications"], .medications)
        XCTAssertEqual(mapped["Notes"], .notes)
        XCTAssertEqual(rows.count, 3)
    }

    func testUnknownLabelFallsBackToName() {
        XCTAssertEqual(ProfileField(rowLabel: "Something else"), .name)
    }

    func testOnlyTheFirstMedicationTakesFocusWhenEditingMedications() {
        let first = Medication(name: "A")
        let second = Medication(name: "B")
        XCTAssertEqual(ProfileField.medications.medicationToFocus(in: [first, second]), first.id)
    }

    func testNoMedicationTakesFocusForOtherBoxesOrAnEmptyList() {
        let med = Medication(name: "A")
        XCTAssertNil(ProfileField.name.medicationToFocus(in: [med]))
        XCTAssertNil(ProfileField.notes.medicationToFocus(in: [med]))
        XCTAssertNil(ProfileField.medications.medicationToFocus(in: []))
    }
}

final class CaretPlacementTests: XCTestCase {
    private func textView(_ text: String) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.string = text
        return view
    }

    func testCaretMovesToTheEndAndSelectsNothing() {
        let view = textView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 11)) // select-all, as SwiftUI does on focus
        CaretPlacement.moveToEnd(in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 11, length: 0))
    }

    func testCaretOnEmptyTextStaysAtZero() {
        let view = textView("")
        CaretPlacement.moveToEnd(in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCaretCountsUTF16UnitsForEmojiAndAccents() {
        let text = "café 😀"
        let view = textView(text)
        CaretPlacement.moveToEnd(in: view)
        XCTAssertEqual(view.selectedRange().location, (text as NSString).length)
        XCTAssertEqual(view.selectedRange().length, 0)
    }

    func testNoTextViewIsANoOp() {
        CaretPlacement.moveToEnd(in: nil)
    }
}
