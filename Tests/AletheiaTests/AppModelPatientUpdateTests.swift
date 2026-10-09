import XCTest
@testable import Aletheia

/// `AppModel.updatePatient` applies a field-level change to the stored patient,
/// so saving one field from a stale view snapshot can't roll back the others.
final class AppModelPatientUpdateTests: XCTestCase {
    /// Records nothing; keeps the tests off the real Spotlight index.
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var appModel: AppModel!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // `AppSettings` is a singleton with no injection point: point it at the
        // temp folder for the test and restore it afterward.
        let settings = AppSettings.shared
        originalDataRoot = settings.dataRootURL
        settings.dataRootURL = tempRoot
        let root = tempRoot!
        let encryption = EncryptionManager(dataRootProvider: { root })
        appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
    }

    override func tearDownWithError() throws {
        appModel = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func storedPatient(_ id: UUID) throws -> Patient {
        let store = try XCTUnwrap(appModel.store)
        return try XCTUnwrap(try store.listPatients().first { $0.id == id })
    }

    func testSavingNotesThenClinicalHistoryKeepsBoth() throws {
        let created = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))

        appModel.updatePatient(id: created.id) { $0.notes = "X" }
        appModel.updatePatient(id: created.id) { $0.clinicalHistory = "GAD" }

        let stored = try storedPatient(created.id)
        XCTAssertEqual(stored.notes, "X")
        XCTAssertEqual(stored.clinicalHistory, "GAD")
        XCTAssertEqual(appModel.patients.first?.notes, "X")
    }

    func testSavingNotesThenMedicationsKeepsBoth() throws {
        let created = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        let meds = [Medication(name: "Sertraline", dose: "50mg")]

        appModel.updatePatient(id: created.id) { $0.notes = "X" }
        appModel.updatePatient(id: created.id) { $0.medications = meds }

        let stored = try storedPatient(created.id)
        XCTAssertEqual(stored.notes, "X")
        XCTAssertEqual(stored.medications, meds)
    }

    func testUpdateIsUnaffectedByAStaleSnapshot() throws {
        let stale = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))

        appModel.updatePatient(id: stale.id) { $0.notes = "X" }
        // The caller still holds `stale` (notes empty); it must not matter.
        appModel.updatePatient(id: stale.id) { $0.clinicalHistory = "GAD" }
        appModel.updatePatient(id: stale.id) { $0.medications = [Medication(name: "A", dose: "1")] }

        let stored = try storedPatient(stale.id)
        XCTAssertEqual(stored.notes, "X")
        XCTAssertEqual(stored.clinicalHistory, "GAD")
        XCTAssertEqual(stored.medications.map(\.name), ["A"])
    }

    func testUpdatingAnUnknownPatientChangesNothing() throws {
        let created = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))

        appModel.updatePatient(id: UUID()) { $0.notes = "lost" }

        XCTAssertEqual(try storedPatient(created.id).notes, "")
    }
}
