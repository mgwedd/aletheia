import XCTest
@testable import Aletheia

/// The pure pre-migration backup policy: where a snapshot goes, how its name
/// round-trips, and which old snapshots are prunable once attested.
final class MigrationBackupTests: XCTestCase {
    private let dbURL = URL(fileURLWithPath: "/data/Aletheia.sqlite")
    private static let t0 = Date(timeIntervalSince1970: 1_600_000_000)

    func testNoSnapshotForFreshOrBaselineDatabase() {
        XCTAssertNil(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 0))
        XCTAssertNil(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: -1))
    }

    func testSnapshotURLLivesInBackupsDirWithParseableName() throws {
        let url = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 2, now: Self.t0))
        XCTAssertEqual(url.deletingLastPathComponent(), MigrationBackup.directory(for: dbURL))
        XCTAssertEqual(url.pathExtension, MigrationBackup.fileExtension)
        XCTAssertTrue(url.lastPathComponent.contains("-pre-v2-"), "name encodes the from-version")
    }

    func testMetadataRoundTrips() throws {
        let url = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 3, now: Self.t0))
        let meta = try XCTUnwrap(MigrationBackup.metadata(of: url))
        XCTAssertEqual(meta.fromVersion, 3)
        XCTAssertEqual(meta.createdAt, Self.t0, "stamp is whole-second precision, so it round-trips exactly")
    }

    func testMetadataParsesWhenBaseNameContainsDashes() throws {
        // A data folder whose db base itself has dashes must still parse (anchors
        // on the last "-pre-v"); use a base that even contains the marker text.
        let dashed = URL(fileURLWithPath: "/data/my-pre-v-notes.sqlite")
        let url = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dashed, fromVersion: 4, now: Self.t0))
        XCTAssertEqual(MigrationBackup.metadata(of: url)?.fromVersion, 4)
    }

    func testMetadataRejectsNonSnapshotNames() {
        XCTAssertNil(MigrationBackup.metadata(of: URL(fileURLWithPath: "/data/Aletheia.sqlite")))
        XCTAssertNil(MigrationBackup.metadata(of: URL(fileURLWithPath: "/data/Backups/random.sqlite")))
        XCTAssertNil(MigrationBackup.metadata(of: URL(fileURLWithPath: "/data/Backups/x-pre-vNaN-20200913.sqlite")))
    }

    func testPrunableKeepsNewestAndIgnoresUnparseable() throws {
        let day: TimeInterval = 86_400
        // Three snapshots on different days (newest last), plus an unrelated file.
        let v1 = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1, now: Self.t0))
        let v2 = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 2, now: Self.t0 + day))
        let v3 = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 3, now: Self.t0 + 2 * day))
        let stray = URL(fileURLWithPath: "/data/Backups/keep-me.txt")

        let prunable = MigrationBackup.prunable([v2, stray, v1, v3], keepMostRecent: 1)
        XCTAssertEqual(Set(prunable), [v1, v2], "keeps the newest one; strays are never pruned")
        XCTAssertFalse(prunable.contains(stray))

        XCTAssertTrue(MigrationBackup.prunable([v1, v2, v3], keepMostRecent: 3).isEmpty, "nothing to prune")
        XCTAssertTrue(MigrationBackup.prunable([v1, v2, v3], keepMostRecent: 9).isEmpty, "keep exceeds count")
    }
}
