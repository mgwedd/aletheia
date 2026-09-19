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
        XCTAssertTrue(BackupExclusion.isExcluded(at: dir))

        try BackupExclusion.setExcluded(false, at: dir)
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }
}
