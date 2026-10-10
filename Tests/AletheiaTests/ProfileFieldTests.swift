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
}
