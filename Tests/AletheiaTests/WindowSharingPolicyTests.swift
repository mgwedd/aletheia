import AppKit
import XCTest
@testable import Aletheia

final class WindowSharingPolicyTests: XCTestCase {
    func testFilePanelsAreCancelledNotHiddenWhileLocked() {
        XCTAssertTrue(WindowSharingPolicy.cancelsWhileLocked(isFilePanel: true))
        XCTAssertFalse(WindowSharingPolicy.cancelsWhileLocked(isFilePanel: false))
        XCTAssertFalse(WindowSharingPolicy.hidesWhileLocked(isSheet: true, isPopover: false, isFilePanel: true))
    }

    @MainActor
    private func makeShield(cancelled: @escaping (NSSavePanel) -> Void, windows: [NSWindow]) -> (WindowShield, AppLock, () -> Void) {
        let suite = "window-sharing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.appLockEnabled = true
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        let shield = WindowShield(
            appLock: appLock, settings: settings, windows: { windows }, cancelFilePanel: cancelled)
        return (shield, appLock, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    func testShieldCancelsOpenAndSavePanelsWhenTheAppLocks() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "Jane Doe - 2026-10-24"
        let open = NSOpenPanel()
        let scene = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var cancelled: [NSSavePanel] = []
        let (shield, appLock, cleanUp) = makeShield(cancelled: { cancelled.append($0) }, windows: [scene, save, open])
        defer { cleanUp() }

        shield.apply()
        XCTAssertTrue(cancelled.isEmpty, "nothing is cancelled while unlocked")

        appLock.lockIfEnabled()
        shield.apply()
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertTrue(cancelled.contains { $0 === save })
        XCTAssertTrue(cancelled.contains { $0 === open })
        XCTAssertFalse(shield.isHidden(save), "a panel is cancelled, not hidden")
        XCTAssertEqual(save.alphaValue, 1)
    }
}
