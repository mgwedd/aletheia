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

    func testDefaultIsNotExcluded() {
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }

    func testExcludeThenIncludeRoundTrips() throws {
        try BackupExclusion.setExcluded(true, at: dir)
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
