import XCTest

final class LicenseSpec: AcceptanceCase {
    func test_LICENSE_01() async throws {
        let getAKey = when.lookAtGetAKey()

        then(getAKey).opensTheBetaApplicationPage()
        then(getAKey).saysNothingIsSent()
    }
}
