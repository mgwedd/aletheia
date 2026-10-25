import XCTest

final class SettingsSpec: AcceptanceCase {
    func test_SETTINGS_01() async throws {
        given.buildIs(.release)

        then(when.openSettings())
            .listsPanes(["General", "AI and models", "Note format", "Backups", "Security", "Licenses"])
        try pending("UI driver: ⌘, opening the Settings window")
    }

    func test_SETTINGS_02() async throws {
        try pending("the folder pointer persists through a bookmark in the app's real preferences, which a hosted test must not rewrite")
    }

    func test_SETTINGS_03() async throws {
        then(when.chooseAppearance(.light)).appliedAtOnce(.light)
        then(when.chooseAppearance(.light)).staysAfterRelaunch(.light)
        then(when.chooseAppearance(.dark)).appliedAtOnce(.dark)
        then(when.chooseAppearance(.dark)).staysAfterRelaunch(.dark)
    }

    func test_SETTINGS_04() async throws {
        then(when.lookAtDefaults()).areTheFreshInstallDefaults()
    }

    func test_SETTINGS_05() async throws {
        then(try await when.downloadSpeechModel()).barFilled()
        try pending("UI driver: the percent bar and the Installed label")
    }

    func test_SETTINGS_06() async throws {
        let picker = when.lookAtEnginePicker()

        then(picker).offersOnly([Copy.automaticEngine, Copy.builtInEngine])
        then(picker).keepsAppleIntelligenceOff()
    }

    func test_SETTINGS_07() async throws {
        then(when.pickBuiltInModels()).eachShowsALicenseLink()
        try pending("UI driver: that the link sits above the download button")
    }

    func test_SETTINGS_08() async throws {
        then(when.downloadStatusLabels(atProgress: [0.4, 1.0])).read([Copy.downloadingModel, Copy.verifyingModel])
    }

    func test_SETTINGS_09() async throws {
        then(when.addRiskPhrase("wants to disappear")).lists("wants to disappear")
        then(when.lookAtRiskPhrases()).isCustomised()
        then(when.removeRiskPhrase("wants to disappear")).doesNotList("wants to disappear")
        then(when.resetRiskPhrases()).isTheDefaultList()
        try pending("UI driver: Reset to Defaults asking before it replaces the list")
    }

    func test_SETTINGS_10() async throws {
        then(when.setNoteFormat("SOAP note", summaryLength: "Detailed", comments: false, background: false))
            .keeps("SOAP note", summaryLength: "Detailed", comments: false, background: false)
    }

    func test_SETTINGS_11() async throws {
        then(when.turnOnRecordingDiagnostics()).wasTurnedOn("Show recording diagnostics")
        try pending("UI driver: the call-audio readout on the recording pane")
    }

    func test_SETTINGS_12() async throws {
        then(when.lookAtLegal()).holdsTermsAndNotices()
        try pending("UI driver: the Consent Guide… button and the pane layout")
    }

    func test_SETTINGS_13() async throws {
        then(when.chooseDataFolderInICloudDrive()).wasRefused(saying: Copy.staysOnThisMac)
        then(when.chooseDataFolderInCloudSyncedFolder()).wasRefused(saying: Copy.staysOnThisMac)
    }

    func test_SETTINGS_14() async throws {
        let move = try when.moveSyncedFolderToThisMac()

        then(move).offersToCopyAndVerify()
        try pending("UI driver: the sheet's Keep original and Delete original choices")
    }
}
