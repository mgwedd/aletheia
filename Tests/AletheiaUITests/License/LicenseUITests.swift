import XCTest

/// The license screen in the real app. Opening the browser is the system's, so
/// the target of the link is checked in the acceptance suite.
final class LicenseUITests: AcceptanceCase {
    func test_LICENSE_01() {
        given.aLicensedApp()

        let pane = when.openLicenseKeySettings()

        then(pane).offersGetAKeyWithItsCaption()
    }
}
