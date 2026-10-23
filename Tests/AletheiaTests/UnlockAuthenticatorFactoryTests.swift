import LocalAuthentication
import XCTest
@testable import Aletheia

final class UnlockAuthenticatorFactoryTests: XCTestCase {
    func testUsesTheSystemSheetOutsideTests() {
        XCTAssertTrue(UnlockAuthenticatorFactory.make(environment: [:]) is SystemUnlockAuthenticator)
        XCTAssertTrue(UnlockAuthenticatorFactory.make(environment: ["HOME": "/Users/x"]) is SystemUnlockAuthenticator)
    }

    func testNeverShowsTheSheetUnderXCTest() {
        let auth = UnlockAuthenticatorFactory.make(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
        XCTAssertTrue(auth is NonPromptingUnlockAuthenticator)
    }

    func testThisTestRunGetsTheNonPromptingAuthenticator() {
        XCTAssertTrue(UnlockAuthenticatorFactory.make() is NonPromptingUnlockAuthenticator)
    }

    func testNonPromptingAuthenticatorReportsACancelAndNeverUnlocks() async {
        do {
            _ = try await NonPromptingUnlockAuthenticator().authenticate(reason: LockScreenCopy.authenticationReason)
            XCTFail("expected a cancel")
        } catch let error as LAError {
            XCTAssertEqual(error.code, .appCancel)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func testAnAppLockBuiltWithDefaultsStaysLockedAndQuietUnderTests() async {
        let settings = AppSettings.shared
        let prior = settings.appLockEnabled
        defer { settings.appLockEnabled = prior }
        settings.appLockEnabled = true

        let lock = AppLock(settings: settings, canAuthenticate: { true }, isAppActive: { true })
        var failures: [String] = []
        lock.onUnlockFailed = { failures.append($0) }
        XCTAssertTrue(lock.isLocked)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertNil(lock.lastError)
        XCTAssertTrue(failures.isEmpty, "a cancel is not a failed-unlock audit entry")
    }
}
