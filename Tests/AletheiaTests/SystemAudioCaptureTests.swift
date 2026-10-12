import ScreenCaptureKit
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

    // MARK: single display fetch

    private struct Fetch: Error {}

    private func declined() -> NSError {
        NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    }

    func testFirstDisplayIsReturnedAfterExactlyOneFetch() async throws {
        var calls = 0
        let display = try await SystemAudioCapture.firstDisplay { () -> [Int] in
            calls += 1
            return [7, 8]
        }
        XCTAssertEqual(display, 7)
        XCTAssertEqual(calls, 1)
    }

    func testNoDisplaysIsReported() async {
        do {
            _ = try await SystemAudioCapture.firstDisplay { () -> [Int] in [] }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .noDisplayAvailable)
        }
    }

    func testUserDeclinedBecomesTheFriendlyPermissionError() async {
        var calls = 0
        do {
            _ = try await SystemAudioCapture.firstDisplay { () -> [Int] in
                calls += 1
                throw self.declined()
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .permissionDenied)
        }
        XCTAssertEqual(calls, 1, "a denied fetch must not be retried or re-probed")
    }

    func testOtherFailuresPassThroughUnchanged() async {
        do {
            _ = try await SystemAudioCapture.firstDisplay { () -> [Int] in throw Fetch() }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Fetch)
        }
    }

    func testOnlyUserDeclinedCountsAsAccessDenied() {
        XCTAssertTrue(SystemAudioCapture.isAccessDenied(declined()))
        XCTAssertFalse(SystemAudioCapture.isAccessDenied(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)))
        XCTAssertFalse(SystemAudioCapture.isAccessDenied(NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
    }
}
