import AppKit

/// When XCTest launches this app to host the unit tests, the app must not
/// prompt for Touch ID, take focus, or draw over whatever the developer is
/// using. CI opts back into a normal foreground app with
/// `TEST_RUNNER_ALETHEIA_FOREGROUND_TESTS=1` (xcodebuild strips the prefix),
/// so the tests that need a key window still run there.
enum TestHost {
    static func isHostingTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Whether the real login Keychain may be used. Under XCTest an ad-hoc
    /// signed build is a new app on every rebuild, so each run would raise a
    /// Keychain access prompt. Tests therefore get an in-memory store unless
    /// opted in, as CI does (smoke-test.yml):
    ///
    ///     TEST_RUNNER_ALETHEIA_LIVE_KEYCHAIN=1 xcodebuild test -scheme Aletheia -destination 'platform=macOS'
    ///
    /// xcodebuild strips the `TEST_RUNNER_` prefix and passes the rest to the
    /// test host, so the app sees `ALETHEIA_LIVE_KEYCHAIN=1`. `CI=true` also
    /// opts in, but only if it reaches the test host, which xcodebuild doesn't
    /// do by itself. Outside XCTest this is always true.
    static func usesLiveKeychain(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !isHostingTests(environment: environment)
            || environment["CI"] == "true"
            || environment["ALETHEIA_LIVE_KEYCHAIN"] == "1"
    }

    /// Hosting tests in the background: no focus, no Dock icon, no visible windows.
    static func runsInBackground(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isHostingTests(environment: environment) && environment["ALETHEIA_FOREGROUND_TESTS"] != "1"
    }

    /// `.prohibited` while hosting tests in the background: the app can't
    /// become frontmost. Nil in normal use.
    static func activationPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSApplication.ActivationPolicy? {
        runsInBackground(environment: environment) ? .prohibited : nil
    }

    /// Makes a window transparent and click-through while hosting tests in
    /// the background. It still lays out and draws, so tests can inspect it.
    @MainActor static func conceal(_ window: NSWindow, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard runsInBackground(environment: environment) else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    /// Conceals the app's own windows (the main window, sheets, alerts) as they appear.
    @MainActor static func concealWindowsWhenHostingTests() {
        guard runsInBackground() else { return }
        NSApp.windows.forEach { conceal($0) }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { conceal(window) }
        }
    }
}
