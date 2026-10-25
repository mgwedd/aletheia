import XCTest
@testable import Aletheia

/// Recording needs a per-patient attestation that the patient agreed to be
/// recorded and to AI processing; it is asked once and survives relaunch.
final class RecordingConsentTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private struct FixedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        originalDataRoot = AppSettings.shared.dataRootURL
        AppSettings.shared.dataRootURL = tempRoot
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeModel() -> AppModel {
        let root = tempRoot!
        let encryption = EncryptionManager(dataRootProvider: { root })
        let model = AppModel(settings: AppSettings.shared, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
        model.diskProbe = FixedDisk()
        return model
    }

    func testGateBlocksUntilAttested() {
        XCTAssertFalse(RecordingConsent.allowsRecording(nil))
        XCTAssertFalse(RecordingConsent.allowsRecording(Patient(name: "A", slug: "a")))
        XCTAssertTrue(RecordingConsent.allowsRecording(Patient(name: "A", slug: "a", recordingConsentAttestedAt: Date())))
    }

    func testNewPatientHasNoConsentUntilAttested() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        XCTAssertFalse(model.hasRecordingConsent(patientID: patient.id))
        XCTAssertTrue(model.attestRecordingConsent(patientID: patient.id))
        XCTAssertTrue(model.hasRecordingConsent(patientID: patient.id))
    }

    func testAttestationSurvivesRelaunch() throws {
        let first = makeModel()
        let patient = try XCTUnwrap(first.addPatient(name: "Jane Doe"))
        let other = try XCTUnwrap(first.addPatient(name: "John Roe"))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(first.attestRecordingConsent(patientID: patient.id, at: when))

        let relaunched = makeModel()
        relaunched.refreshPatients()
        XCTAssertTrue(relaunched.hasRecordingConsent(patientID: patient.id))
        XCTAssertFalse(relaunched.hasRecordingConsent(patientID: other.id), "attestation is per patient")
        let stored = try XCTUnwrap(relaunched.patients.first { $0.id == patient.id })
        XCTAssertEqual(stored.recordingConsentAttestedAt?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
    }

    func testAttestingAgainKeepsTheFirstDateAndLogsOnce() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(model.attestRecordingConsent(patientID: patient.id, at: first))
        XCTAssertTrue(model.attestRecordingConsent(patientID: patient.id, at: first.addingTimeInterval(86_400)))

        let stored = try XCTUnwrap(model.patients.first { $0.id == patient.id })
        XCTAssertEqual(stored.recordingConsentAttestedAt?.timeIntervalSince1970 ?? 0, first.timeIntervalSince1970, accuracy: 1)
        let logged = (model.audit?.entries() ?? []).filter { $0.action == .recordingConsentAttested }
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.subjectID, patient.id.uuidString)
        XCTAssertNil(logged.first?.detail)
    }

    func testUnknownPatientCannotBeAttested() {
        let model = makeModel()
        XCTAssertFalse(model.attestRecordingConsent(patientID: UUID()))
    }

    // MARK: - patient.json compatibility

    func testPatientFileWithoutTheFieldStillLoadsAsUnattested() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","notes":"","createdAt":0,"slug":"old"}
        """
        let patient = try JSONDecoder().decode(Patient.self, from: Data(json.utf8))
        XCTAssertNil(patient.recordingConsentAttestedAt)
    }

    func testAttestationRoundTripsThroughPatientJSON() throws {
        let patient = Patient(name: "A", slug: "a", recordingConsentAttestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder.aletheia.encode(patient)
        let back = try JSONDecoder.aletheia.decode(Patient.self, from: data)
        XCTAssertEqual(back.recordingConsentAttestedAt, patient.recordingConsentAttestedAt)
    }

    func testFolderRelocationKeepsTheAttestation() {
        let patient = Patient(name: "A", slug: "stale", recordingConsentAttestedAt: Date())
        let located = Store.locatedIn(URL(fileURLWithPath: "/tmp/Patients/fresh"), patient)
        XCTAssertEqual(located.slug, "fresh")
        XCTAssertEqual(located.recordingConsentAttestedAt, patient.recordingConsentAttestedAt)
    }
}
