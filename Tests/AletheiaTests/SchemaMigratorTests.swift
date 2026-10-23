import XCTest
@testable import Aletheia

/// The pure migration planner: what to run for a database at a given
/// `user_version`, and the clean refusal of a newer-than-latest file.
final class SchemaMigratorTests: XCTestCase {
    private typealias M = SchemaMigrator.Migration

    // Three synthetic steps, deliberately out of order, to prove the planner
    // sorts and slices rather than trusting the array's arrangement.
    private let steps = [
        M(version: 3, sql: "-- 3"),
        M(version: 1, sql: "-- 1"),
        M(version: 2, sql: "-- 2"),
    ]

    func testShippedMigrationsAreGaplessAndAscending() {
        let versions = SchemaMigrator.migrations.map(\.version)
        XCTAssertEqual(versions, Array(1...versions.count),
                       "steps must be 1-based, gapless, and in order")
        XCTAssertEqual(SchemaMigrator.latestVersion, versions.max())
    }

    func testFreshDatabaseRunsEveryStepInOrder() {
        guard case let .migrate(pending, target) = SchemaMigrator.plan(current: 0, migrations: steps) else {
            return XCTFail("a version-0 database should migrate")
        }
        XCTAssertEqual(pending.map(\.version), [1, 2, 3])
        XCTAssertEqual(target, 3)
    }

    func testPartiallyMigratedDatabaseRunsOnlyPendingSteps() {
        guard case let .migrate(pending, target) = SchemaMigrator.plan(current: 1, migrations: steps) else {
            return XCTFail("a behind database should migrate")
        }
        XCTAssertEqual(pending.map(\.version), [2, 3])
        XCTAssertEqual(target, 3)
    }

    func testUpToDateDatabaseDoesNothing() {
        XCTAssertEqual(SchemaMigrator.plan(current: 3, migrations: steps), .upToDate)
    }

    func testNewerDatabaseIsRefusedNotDowngraded() {
        XCTAssertEqual(
            SchemaMigrator.plan(current: 5, migrations: steps),
            .needsNewerApp(dataVersion: 5, appVersion: 3)
        )
    }

    func testEmptyMigrationListIsUpToDateAtZero() {
        XCTAssertEqual(SchemaMigrator.plan(current: 0, migrations: []), .upToDate)
    }

    func testMigrationV2DefinesAuditLedger() {
        XCTAssertEqual(SchemaMigrator.latestVersion, 2)
        guard let v2 = SchemaMigrator.migrations.first(where: { $0.version == 2 }) else {
            return XCTFail("Migration v2 missing")
        }
        XCTAssertTrue(v2.sql.contains("audit_events"))
        XCTAssertTrue(v2.sql.contains("audit_no_update"))
        XCTAssertTrue(v2.sql.contains("audit_no_delete"))
    }

    func testPlanFromV1ToLatestIncludesV2() {
        guard case let .migrate(steps, target) = SchemaMigrator.plan(current: 1) else {
            return XCTFail("Expected .migrate from v1")
        }
        XCTAssertEqual(steps.map(\.version), [2])
        XCTAssertEqual(target, 2)
    }
}
