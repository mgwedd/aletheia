import AppKit
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

final class TestHostTests: XCTestCase {
    func testDetectsXCTestOnlyFromItsConfigurationVariable() {
        XCTAssertFalse(TestHost.isHostingTests(environment: [:]))
        XCTAssertFalse(TestHost.isHostingTests(environment: ["CI": "true"]))
        XCTAssertTrue(TestHost.isHostingTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        XCTAssertTrue(TestHost.isHostingTests())
    }

    func testTheHostRunsInTheBackgroundUnlessCIAsksForTheForeground() {
        let xctest = ["XCTestConfigurationFilePath": "/x"]
        XCTAssertNil(TestHost.activationPolicy(environment: [:]))
        XCTAssertEqual(TestHost.activationPolicy(environment: xctest), .prohibited)
        XCTAssertTrue(TestHost.runsInBackground(environment: xctest))
        let foreground = xctest.merging(["ALETHEIA_FOREGROUND_TESTS": "1"]) { $1 }
        XCTAssertFalse(TestHost.runsInBackground(environment: foreground))
        XCTAssertNil(TestHost.activationPolicy(environment: foreground))
        XCTAssertFalse(TestHost.runsInBackground(environment: ["ALETHEIA_FOREGROUND_TESTS": "1"]))
    }

    @MainActor
    func testConcealMakesAWindowTransparentAndClickThroughOnlyInTheBackground() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        TestHost.conceal(window, environment: ["XCTestConfigurationFilePath": "/x", "ALETHEIA_FOREGROUND_TESTS": "1"])
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        TestHost.conceal(window, environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    @MainActor
    func testThisRunsTestWindowsMatchTheHostMode() {
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        if TestHost.runsInBackground() {
            XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
            XCTAssertEqual(window.alphaValue, 0)
            XCTAssertTrue(window.ignoresMouseEvents)
        } else {
            XCTAssertEqual(window.alphaValue, 1)
        }
    }
}
