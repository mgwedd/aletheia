import XCTest
@testable import Aletheia

final class SessionNotificationsTests: XCTestCase {
    private let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 16))!

    private let optedIn = PatientLabel.Policy(showFullName: true, isLocked: false)
    private let standard = PatientLabel.Policy(showFullName: false, isLocked: false)
    private let locked = PatientLabel.Policy(showFullName: true, isLocked: true)

    // MARK: Private by default (lock-screen banners)

    func testDefaultBannersShowInitialsOnly() {
        let all = [
            SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: standard),
            SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, policy: standard),
            SessionNotifications.recordingNotDeleted(patientName: "Jane Doe", date: date, policy: standard),
            SessionNotifications.summaryReady(patientName: "Jane Doe", date: date, policy: standard),
            SessionNotifications.longRecordingReminder(patientName: "Jane Doe", policy: standard),
        ]
        for content in all {
            XCTAssertFalse(content.title.contains("Jane"), content.title)
            XCTAssertFalse(content.body.contains("Jane"), content.body)
            XCTAssertFalse(content.body.contains("2026"), content.body)
            XCTAssertFalse(content.body.contains("Sep"), content.body)
        }
        XCTAssertTrue(all[0].body.hasPrefix("J.D.'s session"), all[0].body)
        XCTAssertTrue(all[4].body.hasPrefix("J.D.'s session"), all[4].body)
    }

    func testLockedAppShowsInitialsEvenWhenOptedIn() {
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: locked)
        XCTAssertFalse(content.body.contains("Jane"), content.body)
        XCTAssertFalse(content.body.contains("2026"), content.body)
        XCTAssertTrue(content.body.contains("J.D."), content.body)
        let reminder = SessionNotifications.longRecordingReminder(patientName: "Jane Doe", policy: locked)
        XCTAssertFalse(reminder.body.contains("Jane"), reminder.body)
    }

    func testBlankNameReadsAsClient() {
        let content = SessionNotifications.summaryReady(patientName: "  ", date: date, policy: standard)
        XCTAssertTrue(content.body.contains("Client"), content.body)
    }

    func testIdentifiersNeverCarryTheName() {
        for policy in [optedIn, standard, locked] {
            let ids = [
                SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.recordingNotDeleted(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.summaryReady(patientName: "Jane Doe", date: date, policy: policy).identifier,
                SessionNotifications.longRecordingReminder(patientName: "Jane Doe", policy: policy).identifier,
            ]
            for id in ids { XCTAssertFalse(id.contains("Jane"), id) }
        }
    }

    func testTheSettingIsOffByDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/Services/AppSettings.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(
            "notificationsShowPatientNames = defaults.object(forKey: Keys.notificationsShowPatientNames) as? Bool ?? false"
        ))
    }

    // MARK: Names when the user opts in

    func testTranscriptionCompleteMentionsPatientAndDateWhenOptedIn() {
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("2026"))
        XCTAssertTrue(content.identifier.hasPrefix("transcription-"))
    }

    func testTranscriptionProblemIsDistinctFromSuccess() {
        let content = SessionNotifications.transcriptionProblem(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Transcription needs attention")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertNotEqual(
            content.identifier,
            SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date, policy: optedIn).identifier
        )
    }

    func testSummaryReadyMentionsPatientWhenOptedIn() {
        let content = SessionNotifications.summaryReady(patientName: "John Smith", date: date, policy: optedIn)
        XCTAssertEqual(content.title, "Summary ready")
        XCTAssertTrue(content.body.contains("John Smith"))
        XCTAssertTrue(content.identifier.hasPrefix("summary-"))
    }

    func testIdentifiersAreStableForTheSameSession() {
        let a = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, policy: standard)
        let b = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date, policy: optedIn)
        XCTAssertEqual(a.identifier, b.identifier)
    }

    // MARK: Call sites

    func testSystemNotificationsFollowTheSetting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/App/Services/TranscriptionCoordinator.swift",
            "Sources/App/Views/SessionDetailView.swift",
            "Sources/App/AletheiaApp.swift",
        ]
        for path in files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("showFullName: settings.notificationsShowPatientNames")
                          || source.contains("showFullName: self.settings.notificationsShowPatientNames"), path)
            XCTAssertFalse(source.contains("showFullName: true"), path)
        }
    }

    func testRecordingNotDeletedSaysTheTranscriptIsSaved() {
        let content = SessionNotifications.recordingNotDeleted(patientName: "Jane Doe", date: date, policy: optedIn)
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("was transcribed"))
        XCTAssertFalse(content.body.contains("wasn't transcribed"))
    }
}
