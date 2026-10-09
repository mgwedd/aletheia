import XCTest
@testable import Aletheia

final class PatientBackgroundTests: XCTestCase {
    func testBackgroundBlockFormatsHistoryAndMeds() {
        let patient = Patient(
            name: "Jane Doe",
            slug: "Jane-Doe",
            clinicalHistory: "GAD; started CBT in Jan.",
            medications: [
                Medication(name: "Sertraline", dose: "50mg daily"),
                Medication(name: "Propranolol", dose: "10mg PRN"),
            ]
        )
        let block = patient.aiBackgroundBlock
        XCTAssertTrue(block.contains("Patient background"))
        XCTAssertTrue(block.contains("Clinical history (therapist's summary):\nGAD; started CBT in Jan."))
        XCTAssertTrue(block.contains("- Sertraline: 50mg daily"))
        XCTAssertTrue(block.contains("- Propranolol: 10mg PRN"))
    }

    func testBackgroundBlockOmitsEmptyPartsAndBlankMeds() {
        let patient = Patient(
            name: "Jane",
            slug: "Jane",
            clinicalHistory: "   ",
            medications: [Medication(name: "  ", dose: "10mg"), Medication(name: "Aspirin", dose: "  ")]
        )
        let block = patient.aiBackgroundBlock
        // Blank clinical history contributes nothing; a med with no name is dropped;
        // a med with no dose still lists by name.
        XCTAssertFalse(block.contains("Clinical history"))
        XCTAssertTrue(block.contains("- Aspirin"))
        XCTAssertFalse(block.contains("10mg"))
    }

    func testBackgroundBlockEmptyWhenNothingEntered() {
        let patient = Patient(name: "Jane", slug: "Jane")
        XCTAssertEqual(patient.aiBackgroundBlock, "")
    }

    func testDecodesLegacyPatientJSONWithoutNewFields() throws {
        // patient.json written before medications/clinicalHistory existed.
        let json = """
        {
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "name": "Jane Doe",
          "notes": "prefers mornings",
          "createdAt": "2026-01-02T09:00:00.000Z",
          "slug": "Jane-Doe"
        }
        """
        let patient = try JSONDecoder.aletheia.decode(Patient.self, from: Data(json.utf8))
        XCTAssertEqual(patient.name, "Jane Doe")
        XCTAssertEqual(patient.clinicalHistory, "")
        XCTAssertTrue(patient.medications.isEmpty)
    }

    func testRoundTripsNewFields() throws {
        let patient = Patient(
            name: "Sam",
            slug: "Sam",
            clinicalHistory: "PTSD",
            medications: [Medication(name: "Prazosin", dose: "1mg")]
        )
        let data = try JSONEncoder.aletheia.encode(patient)
        let decoded = try JSONDecoder.aletheia.decode(Patient.self, from: data)
        XCTAssertEqual(decoded.clinicalHistory, "PTSD")
        XCTAssertEqual(decoded.medications, [Medication(id: patient.medications[0].id, name: "Prazosin", dose: "1mg")])
    }

    // MARK: - Notes reach the AI

    func testBackgroundBlockIncludesTherapistNotes() {
        let patient = Patient(
            name: "Jane",
            notes: "  Prefers morning sessions.  ",
            slug: "Jane",
            clinicalHistory: "GAD"
        )
        let block = patient.aiBackgroundBlock
        XCTAssertTrue(block.contains("Therapist's notes on the patient:\nPrefers morning sessions."))
        // History comes first, then notes.
        let history = block.range(of: "Clinical history")!.lowerBound
        let notes = block.range(of: "Therapist's notes")!.lowerBound
        XCTAssertLessThan(history, notes)
    }

    func testBackgroundBlockWithOnlyNotesIsNotEmpty() {
        let patient = Patient(name: "Jane", notes: "Allergic to cats", slug: "Jane")
        XCTAssertTrue(patient.aiBackgroundBlock.contains("Allergic to cats"))
    }

    func testBlankNotesAddNothing() {
        let patient = Patient(name: "Jane", notes: "  \n ", slug: "Jane")
        XCTAssertEqual(patient.aiBackgroundBlock, "")
    }

    // MARK: - Name

    func testNormalizedNameTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(Patient.normalizedName("  Jane   Q.  Doe \n"), "Jane Q. Doe")
        XCTAssertEqual(Patient.normalizedName("Sam"), "Sam")
    }

    func testNormalizedNameRejectsBlank() {
        XCTAssertNil(Patient.normalizedName(""))
        XCTAssertNil(Patient.normalizedName("  \t\n "))
    }

    // MARK: - Profile card rows

    func testProfileRowsListOnlyFilledPartsInOrder() {
        let patient = Patient(
            name: "Jane",
            notes: "Prefers mornings",
            slug: "Jane",
            clinicalHistory: "GAD",
            medications: [Medication(name: "Sertraline", dose: "50mg"), Medication(name: "Aspirin", dose: "")]
        )
        XCTAssertEqual(patient.profileRows(includeMedications: true), [
            Patient.ProfileRow(label: "Clinical history", text: "GAD"),
            Patient.ProfileRow(label: "Medications", text: "Sertraline 50mg, Aspirin"),
            Patient.ProfileRow(label: "Notes", text: "Prefers mornings"),
        ])
    }

    func testProfileRowsHideMedicationsWhenModuleAbsent() {
        let patient = Patient(
            name: "Jane",
            slug: "Jane",
            medications: [Medication(name: "Sertraline", dose: "50mg")]
        )
        XCTAssertTrue(patient.profileRows(includeMedications: false).isEmpty)
    }

    func testProfileRowsEmptyWhenNothingEntered() {
        XCTAssertTrue(Patient(name: "Jane", slug: "Jane").profileRows(includeMedications: true).isEmpty)
    }
}
