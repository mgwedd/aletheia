import SwiftUI
import XCTest
@testable import Aletheia

@MainActor
final class FirstRunGateTests: XCTestCase {
    private func makeSettings() -> (AppSettings, () -> Void) {
        let suite = "first-run-gate-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    func testSheetShowsUntilAllThreeRequirementsAreMet() {
        let (settings, cleanUp) = makeSettings()
        defer { cleanUp() }
        settings.dataRootURL = nil
        XCTAssertTrue(FirstRunGate(settings: settings).sheetShows)

        settings.dataRootURL = FileManager.default.temporaryDirectory
        XCTAssertTrue(FirstRunGate(settings: settings).sheetShows)
        settings.hasCompletedFirstRun = true
        XCTAssertTrue(FirstRunGate(settings: settings).sheetShows, "terms not accepted")
        settings.recordLegalAcceptance(at: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(FirstRunGate(settings: settings).sheetShows)
        settings.recordLegalAcceptance(version: "2000-01-01", at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(FirstRunGate(settings: settings).sheetShows, "older terms")
    }

    func testAskingToDismissLeavesTheSheetUp() {
        let (settings, cleanUp) = makeSettings()
        defer { cleanUp() }
        settings.dataRootURL = nil
        let presented = FirstRunGate.presentation(settings: settings)
        XCTAssertTrue(presented.wrappedValue)
        presented.wrappedValue = false
        XCTAssertTrue(presented.wrappedValue)
    }

    func testFinishNeedsAFolderAndAgreement() {
        XCTAssertFalse(FirstRunFinish.isEnabled(hasDataFolder: false, agreedToTerms: true))
        XCTAssertFalse(FirstRunFinish.isEnabled(hasDataFolder: true, agreedToTerms: false))
        XCTAssertTrue(FirstRunFinish.isEnabled(hasDataFolder: true, agreedToTerms: true))
        XCTAssertEqual(
            FirstRunFinish.hint(hasDataFolder: false, agreedToTerms: true),
            "Choose a data folder above to continue.")
        XCTAssertEqual(
            FirstRunFinish.hint(hasDataFolder: true, agreedToTerms: false),
            "Accept the Terms of Service and Privacy Policy to continue.")
    }

    func testEncryptionStepIsOfferedWithoutBlockingFinish() {
        XCTAssertEqual(FirstRunEncryptionStep(hasDataFolder: false, encryptionOn: false).offer, .chooseFolderFirst)
        XCTAssertEqual(
            FirstRunEncryptionStep(hasDataFolder: true, encryptionOn: false).offer,
            .recommended(button: "Set Up Encryption"))
        XCTAssertEqual(FirstRunEncryptionStep(hasDataFolder: true, encryptionOn: true).offer, .alreadyOn)
        // Finishing takes only a folder and agreement; encryption is not an input.
        XCTAssertTrue(FirstRunFinish.isEnabled(hasDataFolder: true, agreedToTerms: true))
    }

    func testLegalDocumentsAreTheTermsThenThePrivacyPolicy() {
        XCTAssertEqual(Legal.Document.allCases.map(\.title), ["Terms of Service", "Privacy Policy"])
        XCTAssertEqual(Legal.Document.allCases.map(\.url), [Legal.termsURL, Legal.privacyURL])
    }

    func testConsentGuideHasNumberedSectionsAndASampleClause() {
        let titles = ConsentGuideContent.sections.map(\.title)
        XCTAssertGreaterThan(titles.count, 1)
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(title.hasPrefix("\(index + 1). "), title)
        }
        XCTAssertFalse(ConsentGuideContent.sampleClause.isEmpty)
    }

    func testProgressLabelCountsDoneRows() {
        XCTAssertEqual(Setup.Progress(done: 2, total: 6, currentID: nil).label, "2 of 6 done")
    }
}
