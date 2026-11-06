import XCTest

/// The Set up Aletheia sheet in the real app, reached as a returning user whose
/// data folder is missing, so the terms are already accepted.
final class SetupUITests: AcceptanceCase {
    func test_SETUP_13_dataFolderStepSaysWhereToKeepRecords() {
        given.setupWithTermsAcceptedAndNoFolder()

        let sheet = when.lookAtSetup()

        then(sheet).recommendsTheStandardLocationAndSaysWhereOthersMayBe()
    }

    func test_SETUP_14_standardLocationKeepsSetupOpenUntilFinish() {
        given.setupWithTermsAcceptedAndNoFolder()
        let sheet = when.lookAtSetup()

        when.useTheStandardLocation(on: sheet)

        then(sheet).staysUpSayingWhereRecordsAreKept()
        when.finishSetup(on: sheet)
        then(sheet).isGone()
    }

    func test_SETUP_15_intelSetupSuggestsWritingTheSummaryAfterRecording() {
        given.setupOnAnIntelMac(true)
        then(when.lookAtSetup()).suggestsWritingTheSummaryAfterRecording()
    }

    func test_SETUP_15_appleSiliconSetupDoesNotSuggestIt() {
        given.setupOnAnIntelMac(false)
        then(when.lookAtSetup()).doesNotSuggestWritingTheSummaryAfterRecording()
    }
}
