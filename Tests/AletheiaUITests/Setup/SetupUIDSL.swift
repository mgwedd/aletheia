import XCTest

extension Copy {
    static let setupTitle = "Set up Aletheia"
    static let setupUseStandardLocation = "Use the standard location"
    static let setupChooseAnotherFolder = "Choose another folder…"
    static let setupFinish = "Finish setup"
    static let setupFolderRule = "Client records stay in one folder on this Mac. It can't be in iCloud Drive, Dropbox, Google Drive, OneDrive or Box, or on a network drive, and an external disk works only if it's encrypted."
    static let setupFolderRecommendation = "Recommended: the standard location, a private folder on this Mac that only Aletheia uses. There's nothing else to set up."
    static let setupFolderChosenStandard = "Client records will be kept in the standard location on this Mac."
}

/// The Set up Aletheia sheet on screen.
struct SetupSheetOnScreen {
    let driver: AppDriver

    func text(_ words: String) -> XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", words, words))
            .firstMatch
    }

    var title: XCUIElement { text(Copy.setupTitle) }
    var chosenFolder: XCUIElement {
        driver.app.descendants(matching: .any).matching(identifier: "setup-data-folder-chosen").firstMatch
    }
}

extension Given {
    /// Setup was finished and the terms accepted, but no data folder is chosen, so setup is up.
    func setupWithTermsAcceptedAndNoFolder() {
        app.seed { $0.noDataFolder = true }
    }
}

extension When {
    func lookAtSetup() -> SetupSheetOnScreen {
        app.ensureLaunched()
        let sheet = SetupSheetOnScreen(driver: app)
        XCTAssertTrue(app.exists(sheet.title), "no \(Copy.setupTitle) sheet")
        return sheet
    }

    func useTheStandardLocation(on sheet: SetupSheetOnScreen) {
        let button = app.button(Copy.setupUseStandardLocation)
        XCTAssertTrue(app.exists(button), "no \(Copy.setupUseStandardLocation) button")
        button.click()
    }

    func finishSetup(on sheet: SetupSheetOnScreen) {
        let button = app.button(Copy.setupFinish)
        XCTAssertTrue(app.exists(button), "no \(Copy.setupFinish) button")
        button.click()
    }
}

extension Then where Subject == SetupSheetOnScreen {
    func recommendsTheStandardLocationAndSaysWhereOthersMayBe() {
        expect(subject.driver.exists(subject.text(Copy.setupFolderRecommendation)), "no recommendation of the standard location")
        expect(subject.driver.exists(subject.text(Copy.setupFolderRule)), "nothing saying where another folder may be")
        expect(subject.driver.exists(subject.driver.button(Copy.setupUseStandardLocation)), "no \(Copy.setupUseStandardLocation) button")
        expect(subject.driver.exists(subject.driver.button(Copy.setupChooseAnotherFolder)), "no \(Copy.setupChooseAnotherFolder) button")
    }

    func staysUpSayingWhereRecordsAreKept() {
        expect(subject.driver.exists(subject.title), "the setup sheet closed before Finish setup")
        expect(subject.driver.exists(subject.chosenFolder), "the step does not say where client records will be kept")
        expect(subject.driver.exists(subject.text(Copy.setupFolderChosenStandard)),
               "the step should say \"\(Copy.setupFolderChosenStandard)\"")
    }

    func isGone() {
        let gone = subject.title.waitForNonExistence(timeout: AppDriver.timeout)
        expect(gone, "the setup sheet is still up after Finish setup")
    }
}
