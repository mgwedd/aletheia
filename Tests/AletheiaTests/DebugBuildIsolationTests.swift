import XCTest
@testable import Aletheia

final class DebugBuildIsolationTests: XCTestCase {
    /// An installed release build keeps the names its existing data, preferences
    /// and activity-log key were stored under.
    func testReleaseBuildKeepsItsExistingNames() {
        XCTAssertNil(DebugBuildIsolation.defaultsSuite(debug: false))
        XCTAssertEqual(DebugBuildIsolation.dataFolderName(debug: false), "Data")
        XCTAssertEqual(DebugBuildIsolation.auditKeyAccount(debug: false), "com.aletheia.audit-hmac-key")
    }

    /// A Debug build never reads or signs with the release build's data or key.
    func testDebugBuildUsesItsOwnNames() {
        XCTAssertNotNil(DebugBuildIsolation.defaultsSuite(debug: true))
        XCTAssertNotEqual(DebugBuildIsolation.dataFolderName(debug: true), DebugBuildIsolation.dataFolderName(debug: false))
        XCTAssertNotEqual(DebugBuildIsolation.auditKeyAccount(debug: true), DebugBuildIsolation.auditKeyAccount(debug: false))
    }

    /// Tests run in a Debug build, so the live names are the Debug ones.
    func testThisDebugBuildUsesTheDebugNames() {
        XCTAssertTrue(DebugBuildIsolation.isDebugBuild)
        XCTAssertEqual(AuditKeyManager.account, DebugBuildIsolation.auditKeyAccount(debug: true))
        XCTAssertEqual(AppSettings.standardDataRoot.lastPathComponent, DebugBuildIsolation.dataFolderName(debug: true))
        XCTAssertEqual(AppSettings.standardDataRoot.deletingLastPathComponent().lastPathComponent, "Aletheia")
    }
}
