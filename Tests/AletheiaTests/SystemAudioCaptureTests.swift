import ScreenCaptureKit
import XCTest
@testable import Aletheia

/// `SystemAudioCapture.start()` makes one `SCShareableContent` call, so a
/// declined grant must surface as Aletheia's own actionable message rather
/// than a raw ScreenCaptureKit error. The live calls can't run here, but the
/// mapping they feed into can.
final class SystemAudioCaptureTests: XCTestCase {
    func testPermissionDeniedMessageIsActionable() {
        let message = SystemAudioCaptureError.permissionDenied.errorDescription
        XCTAssertTrue(message?.contains("Screen & System Audio Recording") == true)
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
