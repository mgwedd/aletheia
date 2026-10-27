import XCTest

/// RECORD-15 to RECORD-20 through the real window. The system open panel
/// cannot be answered by a UI test, so the scenario's `importFile` hands
/// Import Audio… a fixture file at the point where the panel would return one.
final class ImportAudioTests: XCTestCase {
    private var app = AppDriver()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = AppDriver()
    }

    override func tearDown() {
        app.shutDown()
        super.tearDown()
    }

    private let importButton = "Import Audio…"
    private let recordButton = "Record Session"

    private func scenario(consent: Bool, importFile: String?, fileVault: String? = nil) {
        app.seed {
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: consent)]
            $0.importFile = importFile
            $0.fileVault = fileVault
        }
    }

    /// Opens Jane Doe and her one session, as a click on each would.
    private func openTheSession() {
        app.ensureLaunched()
        let patient = app.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Jane Doe")).firstMatch
        XCTAssertTrue(app.exists(patient), "Jane Doe is not listed")
        patient.click()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let row = app.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", formatter.string(from: Date()))).firstMatch
        XCTAssertTrue(app.exists(row), "her session is not listed")
        row.click()
        XCTAssertTrue(app.exists(app.button(importButton)), "the session does not offer \(importButton)")
    }

    private func hasRecordingFile(_ probe: ProbeSnapshot) -> Bool {
        probe.files.contains { $0.hasSuffix("mic.caf") }
    }

    func test_RECORD_15_importedFileBecomesTheRecording() {
        scenario(consent: true, importFile: "clip")
        openTheSession()

        app.tap(importButton)

        let probe = app.waitForProbe { self.hasRecordingFile($0) }
        XCTAssertTrue(hasRecordingFile(probe), "the session has no recording after the import")
        XCTAssertTrue(app.gone(app.button(importButton)), "\(importButton) is still offered")
        XCTAssertTrue(app.gone(app.button(recordButton)), "\(recordButton) is still offered")
    }

    func test_RECORD_16_consentSheetComesBeforeTheFile() {
        scenario(consent: false, importFile: "clip")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Before you record"]), "no consent sheet")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported before consent")
        let box = app.app.checkBoxes.firstMatch
        XCTAssertTrue(app.exists(box), "no consent checkbox")
        box.click()
        app.tap("Continue")
        let probe = app.waitForProbe { self.hasRecordingFile($0) }
        XCTAssertTrue(hasRecordingFile(probe), "the session has no recording after consent")
    }

    func test_RECORD_17_aFileThatIsNotAudioIsRefused() {
        scenario(consent: true, importFile: "notAudio")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Something went wrong"]), "no alert")
        XCTAssertTrue(app.exists(app.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "couldn't read that file as audio")).firstMatch), "the alert does not say why")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was saved from a file that is not audio")
    }

    func test_RECORD_20_fileVaultOffRefusesTheImport() {
        scenario(consent: true, importFile: "clip", fileVault: "off")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Turn on FileVault"]), "no FileVault alert")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported with FileVault off")
    }
}
