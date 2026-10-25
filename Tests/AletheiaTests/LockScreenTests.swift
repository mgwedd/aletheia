import LocalAuthentication
import SwiftUI
import XCTest
@testable import Aletheia

/// Test double for the system sheet. Counts attempts; `holdOpen` keeps an
/// attempt in flight so overlapping triggers can be observed.
private final class FakeAuthenticator: UnlockAuthenticator, @unchecked Sendable {
    private(set) var reasons: [String] = []
    var result: Result<Bool, Error> = .success(true)
    var holdOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func authenticate(reason: String) async throws -> Bool {
        reasons.append(reason)
        if holdOpen { await withCheckedContinuation { continuation = $0 } }
        return try result.get()
    }

    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class LockScreenTests: XCTestCase {
    private var priorEnabled = false

    override func setUp() {
        super.setUp()
        priorEnabled = AppSettings.shared.appLockEnabled
        AppSettings.shared.appLockEnabled = true
    }

    override func tearDown() {
        AppSettings.shared.appLockEnabled = priorEnabled
        super.tearDown()
    }

    private func makeLock(_ auth: FakeAuthenticator, active: Bool = true) -> AppLock {
        AppLock(settings: .shared, canAuthenticate: { true }, authenticator: auth, isAppActive: { active })
    }

    /// Polls until `condition` holds or `timeout` passes. The button's attempt runs on an
    /// unstructured task; a fixed number of yields only works while the main actor is idle,
    /// and the test host's own work (a busy CI runner) can hold it for longer.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Copy

    func testAuthenticationReasonReadsNaturallyInTheSystemSheet() {
        // macOS renders "<App> is trying to <reason>." (prefix and period are the system's).
        XCTAssertEqual(LockScreenCopy.authenticationReason, "unlock your patient notes")
        XCTAssertEqual("Aletheia is trying to \(LockScreenCopy.authenticationReason).",
                       "Aletheia is trying to unlock your patient notes.")
        XCTAssertFalse(LockScreenCopy.authenticationReason.contains("Aletheia"))
        XCTAssertFalse(LockScreenCopy.authenticationReason.hasSuffix("."))
        XCTAssertEqual(LockScreenCopy.authenticationReason.first?.isLowercase, true)
    }

    func testUnlockPassesTheReasonToTheAuthenticator() async {
        let auth = FakeAuthenticator()
        let lock = makeLock(auth)
        await lock.unlock()
        XCTAssertEqual(auth.reasons, ["unlock your patient notes"])
    }

    func testLockScreenHasNoRemovedTextOrPasswordControl() throws {
        let view = try source("Sources/App/Views/LockView.swift")
        for removed in [
            "Aletheia is locked", "No client names", "Touch ID", "Face ID", "Use Mac Password",
            "Quit Aletheia", "audit log", "explanation", "lockReason",
        ] {
            XCTAssertFalse(view.contains(removed), "LockView still contains \(removed)")
        }
        XCTAssertEqual(LockScreenCopy.unlockLabel, "Unlock")
        XCTAssertTrue(view.contains(".help(LockScreenCopy.unlockLabel)"))
        XCTAssertTrue(view.contains(".accessibilityLabel(LockScreenCopy.unlockLabel)"))
        XCTAssertTrue(view.contains("appLock.requestUnlock()"))
        XCTAssertFalse(try source("Sources/App/Services/AppLock.swift").contains("enum LockReason"))
    }

    func testRenderedLockScreenExposesOnlyTheUnlockButton() {
        let lock = makeLock(FakeAuthenticator(), active: false)
        let host = NSHostingView(rootView: LockView().environmentObject(lock))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        var labels: [String] = []
        func walk(_ element: Any?) {
            guard let object = element as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let value = object.value(forKey: key) as? String, !value.isEmpty { labels.append(value) }
            }
            for child in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child) }
        }
        walk(host)
        for text in labels {
            XCTAssertEqual(text, "Unlock", "unexpected text on the lock screen: \(text)")
        }
        XCTAssertFalse(labels.contains { $0.contains("Password") || $0.contains("Aletheia") })
    }

    // MARK: - Behaviour

    func testLockButtonRequestsAnUnlockAttempt() async {
        let auth = FakeAuthenticator()
        let lock = makeLock(auth)
        lock.lockIfEnabled()
        XCTAssertTrue(lock.isLocked)
        lock.requestUnlock()
        await waitUntil { !lock.isLocked }
        XCTAssertEqual(auth.reasons.count, 1)
        XCTAssertFalse(lock.isLocked)
    }

    func testButtonStillWorksAfterCancellingTheSheet() async {
        let auth = FakeAuthenticator()
        auth.result = .failure(LAError(.userCancel))
        let lock = makeLock(auth)
        lock.lockIfEnabled()
        await lock.unlockIfActive()
        XCTAssertEqual(auth.reasons.count, 1)
        XCTAssertTrue(lock.isLocked)
        XCTAssertNil(lock.lastError, "a cancelled sheet is not an error message")

        auth.result = .success(true)
        await lock.unlock()   // the button is never gated by the auto-prompt gate
        XCTAssertEqual(auth.reasons.count, 2)
        XCTAssertFalse(lock.isLocked)
    }

    func testOpeningTheScreenTriggersExactlyOneAutomaticAttempt() async {
        let auth = FakeAuthenticator()
        auth.holdOpen = true
        let lock = makeLock(auth)
        lock.lockIfEnabled()

        // The view's .task and didBecomeActive fire together; a click lands mid-prompt.
        let first = Task { await lock.unlockIfActive() }
        for _ in 0..<5 { await Task.yield() }
        await lock.unlockIfActive()
        lock.requestUnlock()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(auth.reasons.count, 1)

        auth.release()
        await first.value
        XCTAssertFalse(lock.isLocked)
        await lock.unlockIfActive()   // unlocked now: no further prompt
        XCTAssertEqual(auth.reasons.count, 1)
    }

    func testNoAutomaticAttemptWhileTheAppIsInTheBackground() async {
        let auth = FakeAuthenticator()
        let lock = makeLock(auth, active: false)
        lock.lockIfEnabled()
        await lock.unlockIfActive()
        XCTAssertTrue(auth.reasons.isEmpty)
    }
}
