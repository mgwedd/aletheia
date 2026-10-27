@testable import Aletheia
import Foundation
import XCTest

/// The Get a Key… button in Settings > License key and the words beside it.
/// Whether the browser then opens is the system's; what the button is pointed
/// at, and what the caption promises, are what the user can check.
@MainActor
struct GetAKey {
    let destination: URL
    let caption: String
}

extension When {
    @MainActor
    func lookAtGetAKey() -> GetAKey {
        GetAKey(destination: LicenseLinks.applicationURL, caption: LicensePane.requestCaption)
    }
}

@MainActor
extension Then where Subject == GetAKey {
    func opensTheBetaApplicationPage() {
        expectEqual(subject.destination.absoluteString, Copy.betaApplicationPage, "where Get a Key… opens")
    }

    func saysNothingIsSent() {
        expect(subject.caption.contains(Copy.licenseNothingSent),
               "expected the caption to say \"\(Copy.licenseNothingSent)\", found \"\(subject.caption)\"")
    }
}
