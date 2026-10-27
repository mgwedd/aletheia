import XCTest

extension Copy {
    static let licensePane = "License key"
    static let licenseGetAKey = "Get a Key…"
    static let licenseRequestCaption = "Opens astrealabs.com/aletheia/beta in your browser, where you apply for a key or recover a lost one. Nothing from this Mac is sent. For help, copy the support address and write from your mail app; never include patient information."
}

/// Settings > License key on screen.
struct LicensePaneOnScreen {
    let driver: AppDriver

    var getAKey: XCUIElement { driver.button(Copy.licenseGetAKey) }

    /// The caption may be reported as static text, with its words in the label or the value.
    var caption: XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", Copy.licenseRequestCaption, Copy.licenseRequestCaption))
            .firstMatch
    }
}

extension Given {
    /// A licensed app, so nothing covers the Settings window.
    func aLicensedApp() {
        app.seed { $0.license = "on"; $0.fileVault = "on" }
    }
}

extension When {
    func openLicenseKeySettings() -> LicensePaneOnScreen {
        app.ensureLaunched()
        app.app.typeKey(",", modifierFlags: .command)
        let row = app.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", Copy.licensePane, Copy.licensePane))
            .firstMatch
        XCTAssertTrue(app.exists(row), "no \"\(Copy.licensePane)\" in the Settings sidebar")
        row.click()
        return LicensePaneOnScreen(driver: app)
    }
}

extension Then where Subject == LicensePaneOnScreen {
    /// Clicking it hands the page to the system's browser, which a test cannot observe;
    /// what is checked is that the button is there, with the words that say where it goes.
    func offersGetAKeyWithItsCaption() {
        expect(subject.driver.exists(subject.getAKey), "no \(Copy.licenseGetAKey) button")
        expect(subject.driver.exists(subject.caption), "no caption saying where \(Copy.licenseGetAKey) goes and that nothing is sent")
    }
}
