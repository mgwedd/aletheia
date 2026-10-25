import XCTest

final class SetupSpec: AcceptanceCase {
    func test_SETUP_01() async throws {
        then(when.openFirstRunGate()).sheetShows()
        try pending("UI driver: the sheet can't be dismissed")
    }

    func test_SETUP_02() async throws {
        let checklist = await when.readChecklist()

        then(checklist).listsRows(inOrder: [
            Copy.rowTerms, Copy.rowDataFolder, Copy.rowMicrophone,
            Copy.rowCallAudio, Copy.rowSpeechModel, Copy.rowAI,
        ])
        then(checklist).countsDone()
    }

    func test_SETUP_03() async throws {
        then(when.termsLinks).areTermsAndPrivacyOnGitHub()
        try pending("UI driver: clicking the links opens the default browser")
    }

    func test_SETUP_04() async throws {
        given.noDataFolderChosen()
        then(when.dataFolderRow()).needsButton(Copy.chooseFolderButton, row: .problem)
        when.agreeToTerms()
        then(when.termsRow()).isDone()
        then(when.dataFolderRow()).needsButton(Copy.chooseFolderButton, row: .problem)
        then(when.openFirstRunGate()).sheetShows()
        try pending("UI driver: Finish setup's disabled state")
    }

    func test_SETUP_05() async throws {
        try pending("UI driver: the consent guide's numbered sections and sample clause")
    }

    func test_SETUP_06() async throws {
        given.dataFolderChosen()
        let row = when.dataFolderRow()

        then(row).isDone()
        then(row).detailMentions(when.dataFolderPath)
        try pending("UI driver: the Choose Folder panel")
    }

    func test_SETUP_07() async throws {
        then(when.microphoneRow(.notAskedYet)).needsButton(Copy.allowMicrophoneButton, row: .needsAttention)
        then(when.microphoneRow(.denied)).needsButton(Copy.openSettingsButton, row: .problem)
        then(when.microphoneRow(.allowed)).isDone()
        try pending("UI driver: the macOS microphone prompt")
    }

    func test_SETUP_08() async throws {
        then(when.callAudioRow(granted: false)).needsButton(Copy.allowButton, row: .problem)
        then(when.callAudioRow(granted: true)).isDone()
        then(await when.recheckCallAudioAfterGrant()).isDone()
        try pending("UI driver: granting in System Settings")
    }

    func test_SETUP_09() async throws {
        let speech = when.speechModelRow(installed: false)
        then(speech).needsButton(Copy.downloadButton, row: .problem)
        then(speech).offersDownloadWithSize()
        then(when.speechModelRow(installed: true)).isReadyRow()

        let ai = when.aiRow(installed: false)
        then(ai).needsButton(Copy.downloadButton, row: .problem)
        then(ai).offersDownloadWithSize()
        then(when.aiRow(installed: true)).isReadyRow()
    }

    func test_SETUP_10() async throws {
        then(when.openFirstRunGate()).sheetShows()

        when.agreeToTerms()
        when.finishSetup()
        when.quitAndReopen()

        then(when.openFirstRunGate()).sheetIsGone()
        then(when.receiptExists).isTrue("accepting should leave a receipt in the data folder")
    }

    func test_SETUP_11() async throws {
        given.buildIs(.dev)

        then(when.lookAtEncryptionStep()).isRecommendedOnceFolderChosen()
        try pending("UI driver: the button, and that Finish setup stays enabled")
    }

    func test_SETUP_12() async throws {
        when.agreeToTerms()
        when.finishSetup()
        when.quitAndReopen()
        then(when.openFirstRunGate()).sheetIsGone()
        then(when.receiptExists).isTrue("the acceptance should be kept in the data folder")

        when.openBuildWithNewerTerms()

        then(when.openFirstRunGate()).sheetShows()
    }
}
