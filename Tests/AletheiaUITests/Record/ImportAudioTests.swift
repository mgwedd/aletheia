import XCTest

/// RECORD-15 to RECORD-23 through the real window. The system open panel
/// cannot be answered by a UI test, so the scenario's `importFile` hands
/// Import Audio… fixture files at the point where the panel would return them.
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

    private func scenario(consent: Bool, importFile: String?, fileVault: String? = nil, license: String = "on") {
        app.seed {
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: consent)]
            $0.importFile = importFile
            $0.fileVault = fileVault
            $0.open = "Jane Doe"
            $0.license = license
        }
    }

    /// Launches on Jane Doe's one session (the scenario's `open`). Finding
    /// rows in the sidebar is not what these checks are about.
    private func openTheSession() {
        app.ensureLaunched()
        XCTAssertTrue(app.exists(app.button(importButton)), "the session does not offer \(importButton)")
    }

    /// An alert's message is a static text whose words sit in its value on macOS, not its label.
    private func alertText(containing words: String) -> XCUIElement {
        app.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
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

    func test_RECORD_22_twoFilesBecomeTheMicrophoneAndCallTracks() {
        scenario(consent: true, importFile: "twoTracks")
        openTheSession()

        app.tap(importButton)

        let probe = app.waitForProbe { self.hasRecordingFile($0) && $0.files.contains { $0.hasSuffix("call.caf") } }
        XCTAssertTrue(hasRecordingFile(probe), "the session has no microphone track after the import")
        XCTAssertTrue(probe.files.contains { $0.hasSuffix("call.caf") }, "the session has no call track after the import")
        XCTAssertTrue(app.gone(app.button(importButton)), "\(importButton) is still offered")
    }

    func test_RECORD_23_threeFilesAreRefused() {
        scenario(consent: true, importFile: "threeFiles")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Something went wrong"]), "no alert")
        XCTAssertTrue(app.exists(alertText(containing: "Pick one audio file, or two")), "the alert does not ask for one file or two")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported from three files")
    }

    func test_RECORD_16_consentSheetComesBeforeTheFile() {
        scenario(consent: false, importFile: "clip")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Record consent"]), "no consent sheet")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported before consent")
        let box = app.app.checkBoxes.firstMatch
        XCTAssertTrue(app.exists(box), "no consent checkbox")
        box.click()
        app.tap("Choose Audio File…")
        let probe = app.waitForProbe { self.hasRecordingFile($0) }
        XCTAssertTrue(hasRecordingFile(probe), "the session has no recording after consent")
    }

    func test_RECORD_17_aFileThatIsNotAudioIsRefused() {
        scenario(consent: true, importFile: "notAudio")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Something went wrong"]), "no alert")
        XCTAssertTrue(app.exists(alertText(containing: "couldn't read that file as audio")), "the alert does not say why")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was saved from a file that is not audio")
    }

    func test_RECORD_20_fileVaultOffRefusesTheImport() {
        scenario(consent: true, importFile: "clip", fileVault: "off")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Turn on FileVault"]), "no FileVault alert")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported with FileVault off")
    }

    func test_RECORD_21_withoutALicenseTheImportIsRefused() {
        scenario(consent: true, importFile: "clip", license: "off")
        openTheSession()

        app.tap(importButton)

        XCTAssertTrue(app.exists(app.app.staticTexts["Something went wrong"]), "no alert")
        XCTAssertTrue(app.exists(alertText(containing: "needs a license key")), "the alert does not say a license key is needed")
        XCTAssertFalse(hasRecordingFile(app.probe), "audio was imported without a license")
    }
}
