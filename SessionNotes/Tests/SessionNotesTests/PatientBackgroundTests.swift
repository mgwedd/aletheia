import XCTest
@testable import SessionNotes

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
        let patient = try JSONDecoder.sessionNotes.decode(Patient.self, from: Data(json.utf8))
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
        let data = try JSONEncoder.sessionNotes.encode(patient)
        let decoded = try JSONDecoder.sessionNotes.decode(Patient.self, from: data)
        XCTAssertEqual(decoded.clinicalHistory, "PTSD")
        XCTAssertEqual(decoded.medications, [Medication(id: patient.medications[0].id, name: "Prazosin", dose: "1mg")])
    }
}
