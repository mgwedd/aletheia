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

    /// Reports a fixed disk state (encrypted by default), so the FileVault gate
    /// behaves the same on any Mac.
    private struct FixedDisk: DiskEncryptionProbing {
        var value: Bool? = true
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { value }
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
        appModel.diskProbe = FixedDisk()
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()   // AppModel pointed it at this test's folder
        appModel = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func storedPatient(_ id: UUID) throws -> Patient {
        let store = try XCTUnwrap(appModel.store)
        return try XCTUnwrap(try store.listPatients().first { $0.id == id })
    }

    func testBlankPatientNamesAreRefusedAndCreateNothing() throws {
        XCTAssertNil(appModel.addPatient(name: ""))
        XCTAssertNil(appModel.addPatient(name: "   \n\t"))
        XCTAssertNil(appModel.fileVaultNotice)
        let store = try XCTUnwrap(appModel.store)
        XCTAssertTrue(try store.listPatients().isEmpty)
        XCTAssertThrowsError(try store.createPatient(name: "  ")) {
            guard case StoreError.blankPatientName = $0 else { return XCTFail("wrong error \($0)") }
        }
        XCTAssertTrue(try store.listPatients().isEmpty)
        XCTAssertNotNil(appModel.addPatient(name: "Jane Doe"))
    }

    func testUnencryptedDiskBlocksNewPatientsAndSessionsButKeepsExistingOnes() throws {
        let existing = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        appModel.diskProbe = FixedDisk(value: false)

        XCTAssertNil(appModel.addPatient(name: "John Roe"))
        XCTAssertEqual(appModel.fileVaultNotice, .blocked)
        appModel.fileVaultNotice = nil
        XCTAssertNil(appModel.startNewSession(for: existing))
        XCTAssertEqual(appModel.fileVaultNotice, .blocked)

        let store = try XCTUnwrap(appModel.store)
        XCTAssertEqual(try store.listPatients().map(\.id), [existing.id], "nothing new written, existing record still listed")
        // Editing what's already there isn't gated.
        appModel.updatePatient(id: existing.id) { $0.notes = "X" }
        XCTAssertEqual(try storedPatient(existing.id).notes, "X")
    }

    func testUnknownDiskStateAllowsEntryAndWarnsOnce() throws {
        appModel.diskProbe = FixedDisk(value: nil)

        let patient = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        XCTAssertEqual(appModel.fileVaultNotice, .unknown)
        appModel.fileVaultNotice = nil
        XCTAssertNotNil(appModel.startNewSession(for: patient))
        XCTAssertNil(appModel.fileVaultNotice, "the unknown-state warning shows once per launch")
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

    func testReopenDatabaseRebuildsStore() throws {
        XCTAssertNotNil(appModel.store)
        appModel.reopenDatabase()
        XCTAssertNotNil(appModel.store)
    }

    func testReopenStoreRebuildsStore() throws {
        XCTAssertNotNil(appModel.store)
        appModel.reopenStore()
        XCTAssertNotNil(appModel.store)
    }

    func testDeletePatientRemovesFromPatientsAndWritesAuditLog() throws {
        let created = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        XCTAssertTrue(appModel.patients.contains(where: { $0.id == created.id }))

        try appModel.deletePatient(created)

        XCTAssertFalse(appModel.patients.contains(where: { $0.id == created.id }))

        let auditEntries = appModel.audit?.entries() ?? []
        let deleteEvent = auditEntries.first { $0.action == .phiDeleted }
        XCTAssertNotNil(deleteEvent)
        XCTAssertEqual(deleteEvent?.subjectID, created.id.uuidString)
        XCTAssertEqual(deleteEvent?.detail, "patient")
    }
}

final class BlankPatientNameTests: XCTestCase {
    func testSheetSubmitIgnoresBlankNames() {
        for blank in ["", "   ", "\n\t "] {
            var called = false
            AddPatientSheet.submit(name: blank) { called = true }
            XCTAssertFalse(called, "blank name \(blank.debugDescription) must not submit")
            XCTAssertFalse(AddPatientSheet.canSubmit(blank))
        }
    }

    func testSheetSubmitRunsForRealName() {
        var called = false
        AddPatientSheet.submit(name: "  Jane Doe ") { called = true }
        XCTAssertTrue(called)
        XCTAssertTrue(AddPatientSheet.canSubmit("Jane Doe"))
    }
}
