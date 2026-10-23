import XCTest
@testable import Aletheia

final class IdleAutoLockTimeoutTests: XCTestCase {
    func testChoicesMatchTheOfferedFixedSet() {
        XCTAssertEqual(IdleAutoLockTimeout.allCases.map(\.rawValue), [0, 1, 5, 15, 30, 60])
    }

    func testDefaultTimeoutIsFifteenMinutes() {
        XCTAssertEqual(IdleAutoLockTimeout.defaultTimeout, .fifteenMinutes)
        XCTAssertEqual(IdleAutoLockTimeout.defaultTimeout.rawValue, 15)
    }

    func testOffDisplaysAsNever() {
        XCTAssertEqual(IdleAutoLockTimeout.off.displayName, "Never")
    }

    func testOneMinuteIsSingular() {
        XCTAssertEqual(IdleAutoLockTimeout.oneMinute.displayName, "1 minute")
    }

    func testOtherTimeoutsArePluralMinutes() {
        XCTAssertEqual(IdleAutoLockTimeout.fiveMinutes.displayName, "5 minutes")
        XCTAssertEqual(IdleAutoLockTimeout.fifteenMinutes.displayName, "15 minutes")
        XCTAssertEqual(IdleAutoLockTimeout.thirtyMinutes.displayName, "30 minutes")
        XCTAssertEqual(IdleAutoLockTimeout.sixtyMinutes.displayName, "60 minutes")
    }

    /// `AppSettings` is a UserDefaults-backed singleton with no dependency
    /// injection point, so this round-trips through the real
    /// `UserDefaults.standard` and restores the prior value afterward rather
    /// than leaving test-only state behind for other tests.
    func testIdleAutoLockMinutesPersistsAcrossSettingChanges() {
        let settings = AppSettings.shared
        let original = settings.idleAutoLockMinutes
        defer { settings.idleAutoLockMinutes = original }

        settings.idleAutoLockMinutes = IdleAutoLockTimeout.thirtyMinutes.rawValue
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "idleAutoLockMinutes"), 30)

        settings.idleAutoLockMinutes = IdleAutoLockTimeout.off.rawValue
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "idleAutoLockMinutes"), 0)
    }
}
