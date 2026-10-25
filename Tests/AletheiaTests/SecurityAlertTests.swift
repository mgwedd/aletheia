import XCTest
@testable import Aletheia

/// What the user is told when something security-relevant happens.
final class SecurityAlertTests: XCTestCase {
    private let alerts: [SecurityAlert] = [
        .repeatedUnlockFailures(attempts: 5, minutes: 10),
        .auditLogBroken(entry: 42),
        .recordingEncryptionDeferred,
        .microphoneRestartFailed,
    ]

    func testEveryAlertHasADistinctStableIdentity() {
        XCTAssertEqual(Set(alerts.map(\.id)).count, alerts.count, "one banner per kind")
        XCTAssertEqual(
            SecurityAlert.repeatedUnlockFailures(attempts: 3, minutes: 5).id,
            SecurityAlert.repeatedUnlockFailures(attempts: 9, minutes: 1).id,
            "a repeat of the same kind replaces its banner rather than stacking")
    }

    func testEveryMessageSaysWhatHappenedAndWhatToDo() {
        for alert in alerts {
            XCTAssertGreaterThan(alert.message.count, 40, "\(alert.id)")
            XCTAssertTrue(alert.message.hasSuffix("."), "\(alert.id)")
        }
    }

    func testTheUnlockWarningReportsTheActualCounts() {
        let message = SecurityAlert.repeatedUnlockFailures(attempts: 7, minutes: 3).message
        XCTAssertTrue(message.contains("7 failed unlock attempts within 3 minutes"))
        XCTAssertTrue(message.contains("change your Mac's login password"))
    }

    func testTheAuditWarningNamesTheFirstBrokenEntryAndWhereToLook() {
        let message = SecurityAlert.auditLogBroken(entry: 42).message
        XCTAssertTrue(message.contains("#42"))
        XCTAssertTrue(message.contains("Settings > Security"))
    }

    func testTheDeferredEncryptionNoticeSaysTheRecordingIsSafe() {
        let message = SecurityAlert.recordingEncryptionDeferred.message
        XCTAssertTrue(message.contains("saved"))
        XCTAssertTrue(message.contains("next time it opens"))
    }

    func testTheMicrophoneNoticeSaysTheMicIsNoLongerRecordingAndWhatToDo() {
        let message = SecurityAlert.microphoneRestartFailed.message
        XCTAssertTrue(message.contains("no longer being recorded"))
        XCTAssertTrue(message.contains("Stop the recording"))
    }
}
