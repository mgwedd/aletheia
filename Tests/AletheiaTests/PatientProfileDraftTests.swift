import XCTest
@testable import Aletheia

final class PatientProfileDraftTests: XCTestCase {
    private func patient(medications: [Medication] = []) -> Patient {
        Patient(name: "Jane Doe", slug: "jane", medications: medications)
    }

    func testUntouchedDraftHasNoChangesAndCannotSave() {
        let draft = PatientProfileDraft(patient: patient(), showsMedications: true)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.needsDiscardConfirmation)
    }

    func testBlankNameBlocksSaveAndShowsTheMessage() {
        var draft = PatientProfileDraft(patient: patient(), showsMedications: true)
        draft.notes = "x"
        draft.name = "  "
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.nameProblem, "A name is required.")
    }

    func testApplyTrimsTheNameAndDropsBlankMedicationRows() {
        var draft = PatientProfileDraft(patient: patient(), showsMedications: true)
        draft.name = "  Jane   Q  Doe "
        draft.addMedication()
        draft.addMedication()
        draft.medications[1] = Medication(name: "Lithium", dose: "")
        var saved = patient()
        draft.apply(to: &saved)
        XCTAssertEqual(saved.name, "Jane Q Doe")
        XCTAssertEqual(saved.medications.map(\.name), ["Lithium"])
    }

    func testApplyKeepsStoredMedicationsWhenTheTableIsHidden() {
        let stored = [Medication(name: "Sertraline", dose: "50 mg")]
        var draft = PatientProfileDraft(patient: patient(medications: stored), showsMedications: false)
        draft.notes = "Seen"
        var saved = patient(medications: stored)
        draft.apply(to: &saved)
        XCTAssertEqual(saved.medications, stored)
        XCTAssertEqual(saved.notes, "Seen")
    }

    func testEditsKeptFromALockStartTypedInAndCountAsChanges() {
        var kept = patient()
        kept.notes = "Typed before the lock"
        let draft = PatientProfileDraft(patient: patient(), showsMedications: true, edits: kept)
        XCTAssertEqual(draft.notes, "Typed before the lock")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.edited.notes, "Typed before the lock")
        XCTAssertEqual(draft.original.notes, "")
    }

    func testDeletionConfirmationIgnoresCaseAndOuterSpaces() {
        XCTAssertTrue(PatientDeletionConfirmation.matches(typed: " jane doe ", patientName: "Jane Doe"))
        XCTAssertFalse(PatientDeletionConfirmation.matches(typed: "Jane", patientName: "Jane Doe"))
    }

    func testSessionTexts() {
        XCTAssertEqual(PatientSessionText.summary(count: 0), "No sessions")
        XCTAssertEqual(PatientSessionText.summary(count: 1), "1 session")
        XCTAssertEqual(PatientSessionText.summary(count: 3), "3 sessions")
        let added = PatientSessionText.rowSubtitle(patient: patient(), count: 0, newest: nil)
        XCTAssertTrue(added.hasPrefix("Added "))
        let one = PatientSessionText.rowSubtitle(patient: patient(), count: 1, newest: Date())
        XCTAssertTrue(one.hasPrefix("1 session · "))
    }
}
