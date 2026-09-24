import XCTest
@testable import Aletheia

/// `BackupExclusion` round-trips the `isExcludedFromBackup` flag on a folder, so
/// the data folder can be kept out of (or allowed back into) Time Machine and
/// iCloud's device backup.
final class BackupExclusionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Whether this process runs inside an App Sandbox container.
    ///
    /// The app ships sandboxed (`com.apple.security.app-sandbox`), so an
    /// `xcodebuild` test host is sandboxed too. `isExcludedFromBackup` is then a
    /// no-op on any path this test can reach: `FileManager.temporaryDirectory`
    /// resolves *inside* the container (`~/Library/Containers/<id>/Data/tmp`),
    /// which the system already keeps out of backups, so setting the flag there
    /// succeeds without error but doesn't read back. In production the flag is
    /// applied to the **user-selected** data folder — outside the container, with
    /// the `files.user-selected.read-write` entitlement — where it *is* honored;
    /// that path needs a user grant at runtime and can't be reached from an
    /// automated test. So the read-back is asserted only where it's meaningful
    /// (an unsandboxed run, e.g. `swift test`) and capability-guarded elsewhere.
    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || NSHomeDirectory().contains("/Library/Containers/")
    }

    func testDefaultIsNotExcluded() {
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }

    func testExcludeThenIncludeRoundTrips() throws {
        // The write path must always work without throwing, sandbox or not — this
        // exercises `setExcluded` on every runner.
        XCTAssertNoThrow(try BackupExclusion.setExcluded(true, at: dir))

        // The flag's read-back is an OS behavior the App Sandbox container doesn't
        // honor (see `isSandboxed`); assert it only where it's meaningful.
        try XCTSkipIf(isSandboxed,
                      "isExcludedFromBackup is a no-op inside the App Sandbox container; the round-trip is exercised on the user-selected data folder, which an automated test can't reach.")

        XCTAssertTrue(excludedFlag(becomes: true), "excluded flag should read back true after being set")

        try BackupExclusion.setExcluded(false, at: dir)
        XCTAssertTrue(excludedFlag(becomes: false), "excluded flag should read back false after being cleared")
    }

    /// Polls `isExcluded` until it reaches `expected` (or a short deadline). The
    /// `isExcludedFromBackup` resource value is filesystem metadata whose
    /// visibility after a write can lag briefly on some volumes (seen as an
    /// intermittent read-back miss on CI runners), so a set-then-immediate-read
    /// can race. This still asserts the value actually reaches `expected` — it
    /// just tolerates that lag instead of flaking on it. Returns `false` if the
    /// deadline passes without the value settling.
    private func excludedFlag(becomes expected: Bool, within timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if BackupExclusion.isExcluded(at: dir) == expected { return true }
            usleep(50_000) // 50ms
        } while Date() < deadline
        return BackupExclusion.isExcluded(at: dir) == expected
    }
}
