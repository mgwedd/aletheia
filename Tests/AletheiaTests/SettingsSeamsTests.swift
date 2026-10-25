import XCTest
@testable import Aletheia

@MainActor
final class SettingsSeamsTests: XCTestCase {
    func testModelCardListsTheLicenseBeforeAnythingThatDownloads() {
        let idle = ModelCardPresentation(installed: false, isDownloading: false, progress: 0, sizeMB: 466)
        XCTAssertEqual(idle.chip, "Not downloaded")
        XCTAssertEqual(idle.rows, [.picker, .licenseLink, .downloadPrompt(sizeMB: 466)])

        let busy = ModelCardPresentation(installed: false, isDownloading: true, progress: 0.4, sizeMB: 466)
        XCTAssertEqual(busy.chip, "Downloading")
        XCTAssertEqual(busy.rows, [.picker, .licenseLink, .progress(fraction: 0.4)])
        XCTAssertEqual(ModelCardPresentation.percentText(0.4), "40%")

        let done = ModelCardPresentation(installed: true, isDownloading: false, progress: 1, sizeMB: 466)
        XCTAssertEqual(done.chip, "Installed")
        XCTAssertEqual(done.rows, [.picker, .licenseLink, .installed])
    }

    func testResetAndClearWaitForConfirmation() {
        let suite = "risk-editor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.addRiskPhrase("custom phrase")
        var editor = RiskPhraseEditor()

        editor.askToReset()
        XCTAssertEqual(editor.pending, .resetToDefaults)
        XCTAssertTrue(settings.riskPhrases.contains("custom phrase"), "nothing changes before the yes")
        editor.cancel()
        XCTAssertNil(editor.pending)
        XCTAssertTrue(settings.riskPhrases.contains("custom phrase"))

        RiskPhraseEditor.apply(.resetToDefaults, to: settings)
        XCTAssertEqual(settings.riskPhrases, LongSessionNote.defaultRiskPhrases)
        RiskPhraseEditor.apply(.clearAll, to: settings)
        XCTAssertTrue(settings.riskPhrases.isEmpty)
    }

    func testDiagnosticsReadoutAppearsOnlyWhenSwitchedOn() {
        let diagnostics = CallAudioDiagnostics(
            preflightGranted: true, currentBuild: "1+1", confirmedBuild: nil, attemptedThisLaunch: false,
            workedThisLaunch: false, lastStart: .notTried, streamRunning: false, streamDisrupted: false,
            buffersReceived: 0, bytesWritten: nil, disruptions: 0, firstFailure: nil)
        XCTAssertNil(RecordingDiagnostics.readout(enabled: false, current: { diagnostics }))
        XCTAssertEqual(RecordingDiagnostics.readout(enabled: true, current: { diagnostics })?.count, diagnostics.rows.count)
    }

    func testLegalCardHoldsBothDocumentsAndTheConsentGuide() {
        XCTAssertEqual(SettingsLegalItem.all.map(\.id), ["Terms of Service", "Privacy Policy", "Consent Guide…"])
    }

    func testDataFolderRowShowsThePath() {
        XCTAssertEqual(DataFolderDisplay.text(for: nil), "Not chosen yet")
        XCTAssertEqual(DataFolderDisplay.text(for: URL(fileURLWithPath: "/tmp/x")), "/tmp/x")
    }

    func testDeletingTheOriginalRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DataFolderMove.deleteOriginal(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDataFolderBookmarkPersistsInTheSettingsOwnDefaults() throws {
        let suite = "bookmark-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try AppSettings(defaults: defaults).setDataRoot(folder)
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.dataRootURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }
}
