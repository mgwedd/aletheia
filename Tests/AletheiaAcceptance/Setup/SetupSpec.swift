import XCTest

final class SetupSpec: AcceptanceCase {
    func test_SETUP_01() async throws {
        then(when.openFirstRunGate()).sheetShows()
        then(when.sheetStaysUpAfterTryingToClose()).isTrue("asking to close the sheet should leave it up")
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
    }

    func test_SETUP_04() async throws {
        given.noDataFolderChosen()
        then(when.dataFolderRow()).needsButton(Copy.chooseFolderButton, row: .problem)
        when.agreeToTerms()
        then(when.termsRow()).isDone()
        then(when.dataFolderRow()).needsButton(Copy.chooseFolderButton, row: .problem)
        then(when.openFirstRunGate()).sheetShows()
        then(when.finishButton()).isDisabled()
        then(when.finishButton()).asksFor("data folder")
    }

    func test_SETUP_05() async throws {
        then(when.readConsentGuide()).areNumbered()
        then(when.consentSampleClause).isASampleConsentClause()
    }

    func test_SETUP_06() async throws {
        given.noDataFolderChosen()
        when.agreeToTerms()
        try await when.chooseFolder(app.root)
        let row = when.dataFolderRow()

        then(row).isDone()
        then(row).detailMentions(when.dataFolderPath)
        then(when.finishButton()).isEnabled()
    }

    func test_SETUP_07() async throws {
        then(when.microphoneRow(.notAskedYet)).needsButton(Copy.allowMicrophoneButton, row: .needsAttention)
        let denied = try await when.allowMicrophone(answer: .denied)
        then(denied).asksMacOS()
        then(denied).leavesRow(.problem, button: Copy.openSettingsButton)
        then(when.microphoneRow(.allowed)).isDone()
    }

    func test_SETUP_08() async throws {
        then(when.callAudioRow(granted: false)).needsButton(Copy.allowButton, row: .problem)
        then(when.callAudioRow(granted: true)).isDone()
        then(await when.recheckCallAudioAfterGrant()).isDone()

        let click = try await when.allowCallAudio(grantedInSettingsAtLook: 3)
        then(click).sendsYouToSystemSettings()
        then(click).turnsDoneWithoutRestart()
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
        then(when.lookAtEncryptionStep()).doesNotBlockFinish()
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

    func test_SETUP_13() async throws {
        given.noDataFolderChosen()

        let step = when.readDataFolderStep()

        then(step).recommendsTheStandardLocationOnThisMac()
        then(step).saysWhereOtherFoldersMayBe()
    }

    func test_SETUP_14() async throws {
        when.agreeToTerms()
        when.finishSetup()
        given.noDataFolderChosen()
        when.setupSheetAppears()

        try await when.chooseFolder(app.root)

        then(when.openFirstRunGate()).sheetShows()
        then(when.readDataFolderStep()).saysRecordsWillBeKept(in: when.dataFolderPath)
        when.finishSetup()
        then(when.openFirstRunGate()).sheetIsGone()
    }
}
