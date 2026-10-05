import XCTest
@testable import Aletheia

/// `SystemAudioCapture.start()` used to go straight to `SCShareableContent`
/// with no permission pre-check, so an unauthorized attempt surfaced a raw
/// ScreenCaptureKit error instead of Aletheia's own actionable message. This
/// pins the pure mapping that fixes that (issue #110's "Record ... fails"
/// half): the live ScreenCaptureKit/CoreGraphics calls can't run here, but the
/// decision they feed into can.
final class SystemAudioCaptureTests: XCTestCase {
    func testGrantedProducesNoError() {
        XCTAssertNil(SystemAudioCapture.permissionError(granted: true))
    }

    func testNotGrantedProducesPermissionDeniedWithActionableMessage() {
        let error = SystemAudioCapture.permissionError(granted: false)
        XCTAssertEqual(error, .permissionDenied)
        XCTAssertEqual(error?.errorDescription, SystemAudioCaptureError.permissionDenied.errorDescription)
        XCTAssertTrue(error?.errorDescription?.contains("Screen & System Audio Recording") == true)
    }
}
